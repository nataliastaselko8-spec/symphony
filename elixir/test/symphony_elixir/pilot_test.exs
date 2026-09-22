defmodule SymphonyElixir.PilotTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DeliveryGate.{Migration, Pilot, Settings, Snapshot, Store}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  @scope %{"repo" => "exampleorg/app"}

  defp append(snapshot, action, args) do
    n = snapshot["revision"]
    assert {:ok, next, :new} = Snapshot.append(snapshot, "event-#{n}", n, action, args, n)
    next
  end

  defp reviewed do
    Snapshot.new(@scope)
    |> append("bootstrap", G.validation())
    |> append("reserve", G.task())
    |> append("reserve_ci", G.ci_request())
    |> append("observe_ci", G.ci_result())
    |> append("handoff", %{"pr_number" => 7, "sha" => G.sha("b")})
  end

  defp ready do
    reviewed()
    |> append("merged", %{"pr_number" => 7, "sha" => G.sha("c")})
    |> append("deployment", G.deployment())
    |> append("validate_dev", G.passed())
  end

  defp intent(snapshot, action, args),
    do: append(snapshot, "status_transition", %{"action" => action, "args" => args, "from" => "Dev validation", "reason" => "Verified transition", "repo" => "ExampleOrg/app"})

  defp confirm(snapshot) do
    op = List.last(snapshot["state"]["status_sync"])
    append(snapshot, "status_result", %{"operation_id" => op["id"], "outcome" => "confirmed", "observed" => "Ready for production", "error" => nil, "at_ms" => 100, "retry_at_ms" => 0})
  end

  defp migration_configs do
    provider = %{
      "organization" => "ExampleOrg",
      "repo" => "ExampleOrg/app",
      "project_number" => 1,
      "token" => "fixture",
      "item_ids" => ["item-A"],
      "agent_allowed_value" => "yes",
      "states" => %{"ready" => "Ready for agent", "working" => "Agent working", "blocked" => "Needs human decision", "handoff" => "PR ready"}
    }

    before = %{
      "tracker" => %{"kind" => "github_projects", "provider" => provider, "active_states" => ["Ready for agent", "Agent working"], "terminal_states" => ["Done"]},
      "workspace" => %{"root" => "/workspace"},
      "delivery" => %{"state_path" => "/private/before/delivery.json", "base_branch" => "dev"}
    }

    proposed =
      before
      |> put_in(
        ["tracker", "provider", "states"],
        Map.merge(provider["states"], %{
          "review" => "Human review",
          "dev_validation" => "Dev validation",
          "production_ready" => "Ready for production"
        })
      )
      |> put_in(["delivery", "state_path"], "/private/after/delivery.json")

    {:ok, old} = Schema.parse(before)
    {:ok, target} = Schema.parse(proposed)
    {:ok, old_gate} = Settings.from_config(old)
    {:ok, new_gate} = Settings.from_config(target)
    {before, proposed, old_gate.scope, new_gate.scope}
  end

  test "explicit settled migration retains original replay and completion while invalidating baseline" do
    {before, proposed, old_scope, new_scope} = migration_configs()
    source = ready() |> append("complete", G.proof("c")) |> Map.put("scope", old_scope)
    assert {:ok, migrated} = Migration.prepare(source, before, proposed)
    assert migrated["state"]["last_cycle"] == source["state"]["last_cycle"]
    assert migrated["state"]["baseline"] == nil
    refute Map.has_key?(migrated["state"], "status_sync")
    assert migrated["migration"]["source"] == source
    assert {:ok, ^migrated} = Snapshot.decode(Jason.decode!(Jason.encode!(migrated)), new_scope)
    assert {:ok, %{"status_sync" => "legacy_not_recorded"}} = Pilot.inspect(migrated, new_scope, ["item-A"])
    assert {:error, _} = Snapshot.decode(migrated, old_scope)
    extended = append(migrated, "invalidate_queue_confirmation", %{})
    assert {:ok, ^extended} = Snapshot.decode(extended, new_scope)
  end

  test "migration refuses active or changed contracts and tampered migration evidence" do
    {before, proposed, old_scope, new_scope} = migration_configs()
    source = ready() |> append("complete", G.proof("c")) |> Map.put("scope", old_scope)
    assert {:error, _} = Migration.prepare(Map.put(reviewed(), "scope", old_scope), before, proposed)
    assert {:error, _} = Migration.prepare(source, before, put_in(proposed, ["tracker", "provider", "repo"], "ExampleOrg/other"))
    assert {:error, _} = Migration.prepare(source, before, put_in(proposed, ["tracker", "provider", "states", "ready"], "Other"))
    assert {:ok, migrated} = Migration.prepare(source, before, proposed)
    assert {:error, _} = Snapshot.decode(put_in(migrated, ["migration", "version"], 2), new_scope)
    assert {:error, _} = Snapshot.decode(put_in(migrated, ["migration", "source", "state", "baseline"], nil), new_scope)
    assert {:error, _} = Snapshot.decode(%{migrated | "commands" => source["commands"]}, new_scope)
    assert {:error, _} = Migration.prepare(migrated, proposed, proposed)
    empty_before = put_in(before, ["tracker", "provider", "item_ids"], [])
    empty_after = put_in(proposed, ["tracker", "provider", "item_ids"], [])
    assert {:ok, fresh} = Migration.prepare(nil, empty_before, empty_after)
    assert fresh["state"]["last_cycle"] == nil
    assert {:error, _} = Snapshot.decode(%{"scope" => new_scope, "commands" => [], "schema_version" => 999}, new_scope)
  end

  test "initial profile requires no selected task; a legacy completed journal retains its limitation" do
    assert {:ok, %{"kind" => "initial"}} = Pilot.inspect(nil, @scope, [])
    assert {:error, :invalid_snapshot} = Pilot.inspect(false, @scope, [])
    assert {:error, :pilot_completion_required} = Pilot.inspect(nil, @scope, ["item-A"])
    snapshot = append(ready(), "complete", G.proof("c"))
    assert {:ok, proof} = Pilot.inspect(snapshot, @scope, ["item-A"])
    assert proof["kind"] == "completed" and proof["status_sync"] == "legacy_not_recorded"
    assert proof["work"]["pr_number"] == 7 and proof["completion"] == G.proof("c")
    assert {:error, _} = Pilot.inspect(snapshot, @scope, [])
    assert {:error, _} = Pilot.inspect(snapshot, @scope, ["other"])
    assert {:error, :invalid_snapshot} = Pilot.inspect(snapshot, %{"repo" => "other/app"}, ["item-A"])
    assert {:error, :invalid_snapshot} = Pilot.inspect(put_in(snapshot, ["state", "baseline", "sha"], G.sha("d")), @scope, ["item-A"])
  end

  test "final sync must be confirmed and retained; a historical unrelated status is insufficient" do
    pending = intent(ready(), "complete", G.proof("c"))
    assert {:error, :pilot_status_sync_pending} = Pilot.inspect(pending, @scope, ["item-A"])
    assert {:ok, %{"status_sync" => %{"status" => "confirmed", "role" => "production_ready"}}} = Pilot.inspect(confirm(pending), @scope, ["item-A"])
    wrong = reviewed() |> intent("review_started", %{}) |> confirm()

    wrong =
      wrong
      |> append("merged", %{"pr_number" => 7, "sha" => G.sha("c")})
      |> append("deployment", G.deployment())
      |> append("validate_dev", G.passed())
      |> append("complete", G.proof("c"))

    assert {:error, :pilot_completion_unconfirmed} = Pilot.inspect(wrong, @scope, ["item-A"])
  end

  test "active, paused, environment-problem and cancelled owners cannot switch pilots" do
    assert {:error, _} = Pilot.inspect(reviewed(), @scope, ["item-A"])
    complete = append(ready(), "complete", G.proof("c"))

    for kind <- ~w(pause problem) do
      args = %{"kind" => kind, "actor" => "local:owner", "reason" => "Hold", "request_hash" => String.duplicate("a", 64), "data" => %{}}
      assert {:error, _} = Pilot.inspect(append(complete, "operator_decision", args), @scope, ["item-A"])
    end

    cancelled = Snapshot.new(@scope) |> append("bootstrap", G.validation()) |> append("reserve", G.task()) |> append("request_cancel", G.operator())
    cancelled = append(cancelled, "finish_cancel", Map.merge(G.validation(), G.operator()))
    assert {:error, :pilot_completion_required} = Pilot.inspect(cancelled, @scope, ["item-A"])
  end

  @tag skip: :os.type() != {:unix, :linux}
  test "real private store replay produces stable evidence without rewriting completed state" do
    root = Path.join(System.tmp_dir!(), "pilot-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "delivery.json")
    snapshot = ready() |> intent("complete", G.proof("c")) |> confirm()
    assert {:ok, store} = Store.open(path)

    try do
      assert {:ok, nil} = Store.request(store, %{"op" => "read"})
      assert {:ok, true} = Store.request(store, %{"op" => "write", "snapshot" => snapshot})
      original = File.read!(path)
      assert {:ok, saved} = Store.request(store, %{"op" => "read"})
      assert {:ok, first} = Pilot.inspect(saved, @scope, ["item-A"])
      assert {:ok, ^first} = Pilot.inspect(saved, @scope, ["item-A"])
      assert File.read!(path) == original
    after
      Store.close(store)
    end
  end
end
