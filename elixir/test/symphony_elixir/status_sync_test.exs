defmodule SymphonyElixir.StatusSyncTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DeliveryGate.{Snapshot, State, StatusSync}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.Observation
  alias SymphonyElixir.GitHubProjects.StatusSync, as: Remote

  defp command(action, args, from \\ "Agent working", id \\ "event") do
    %{
      "id" => id,
      "expected_revision" => 4,
      "at_ms" => 1000,
      "args" => %{
        "action" => action,
        "args" => args,
        "from" => from,
        "repo" => "ExampleOrg/app",
        "reason" => "Verified controller event"
      }
    }
  end

  defp record(state, action, args, from \\ "Agent working", id \\ "event") do
    {:ok, next} = StatusSync.transition(state, command(action, args, from, id))
    {next, List.last(StatusSync.operations(next))}
  end

  defp result(state, id, outcome, observed \\ nil) do
    StatusSync.result(state, %{"operation_id" => id, "outcome" => outcome, "observed" => observed, "error" => nil, "at_ms" => 2000, "retry_at_ms" => 3000})
  end

  setup do
    f = F.fixture()
    roles = Map.merge(f.settings.project.states, %{"review" => "Human review", "dev_validation" => "Dev validation", "production_ready" => "Ready for production"})
    raw = put_in(f.raw, ["tracker", "provider", "states"], roles)
    {:ok, config} = Schema.parse(raw)
    {:ok, settings} = Config.delivery_observer_settings(config)
    {state, op} = record(G.initial(), "block", %{"reason" => "Worker failed"})

    row = %{
      "item_id" => "item-A",
      "state" => "Agent working",
      "archived" => false,
      "in_scope" => true,
      "reasons" => [],
      "issue_state" => "OPEN",
      "native_ref" => %{"issue_id" => "issue-A", "repo" => "ExampleOrg/app", "agent_allowed_option_id" => "yes"}
    }

    report = %{
      "project" => %{"id" => "project", "repo" => "ExampleOrg/app"},
      "items" => [row],
      "schema" => %{"agent_allowed_option_id" => "yes", "status" => %{"id" => "status", "options" => Enum.map(roles, fn {id, name} -> %{"id" => id, "name" => name} end)}}
    }

    initial = %{report: report, writes: 0, calls: 0, failure: nil, read_failure: nil, after_failure: nil}
    remote = start_supervised!({Agent, fn -> initial end})
    cache = start_supervised!(F.Cache)

    opts = [
      credentials_cache: cache,
      project_reader: fn _, _ ->
        Agent.get_and_update(remote, fn r -> {r.read_failure || {:ok, r.report}, %{r | calls: r.calls + 1}} end)
      end,
      http: fn options ->
        Agent.get_and_update(remote, fn r ->
          if r.failure do
            {r.failure, r}
          else
            assert options[:json]["query"] =~ "SymphonyStatus"
            target = options[:json]["variables"]["input"]["value"]["singleSelectOptionId"]
            updated = update_in(r, [:report, "items"], fn [row] -> [Map.put(row, "state", roles[target])] end)
            {r.after_failure || F.ok(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "item-A"}}}}), %{updated | writes: r.writes + 1}}
          end
        end)
      end
    ]

    context = %{version: %{epoch: "e", revision: 5}, mode: :needs_reconciliation, state: state}
    %{config: config, settings: settings, state: state, op: op, context: context, remote: remote, opts: opts}
  end

  test "legacy journal replay stays byte-shape compatible; new transition and intent are atomic" do
    s = Snapshot.new(%{"repo" => "ExampleOrg/app"})
    {:ok, s, :new} = Snapshot.append(s, "boot", 0, "bootstrap", G.validation(), 0)
    {:ok, s, :new} = Snapshot.append(s, "reserve", 1, "reserve", G.task(), 1)
    assert {:ok, ^s} = Snapshot.decode(s, s["scope"])
    refute Map.has_key?(s["state"], "status_sync")
    args = command("block", %{"reason" => "failed"})["args"]
    {:ok, next, :new} = Snapshot.append(s, "block", 2, "status_transition", args, 1000)
    assert next["state"]["cycle"]["phase"] == "needs_human_decision"
    assert [op] = StatusSync.operations(next["state"])
    assert op["sequence"] == 3
    assert {:ok, ^next} = Snapshot.decode(next, next["scope"])
    assert {:ok, ^next, :replayed} = Snapshot.append(next, "block", 2, "status_transition", args, 9999)
    assert {:error, :command_id_reused} = Snapshot.append(next, "block", 3, "status_transition", args, 9999)
  end

  test "completion retains intent and blocks next task until confirmation" do
    {state, op} = record(G.ready(), "complete", G.proof("c"), "Dev validation")
    assert state["cycle"] == nil and state["last_cycle"]["phase"] == "completed"
    assert op["role"] == "production_ready"
    assert {:error, :status_sync_pending} = State.admission(state, "new")
    assert {:error, :unvalidated_base} = State.apply_command(state, "reserve", %{G.task() | "sha" => G.sha("c")})
    assert {:ok, state} = result(state, op["id"], "confirmed", "Ready for production")
    assert :ok = State.admission(state, "new")
    assert StatusSync.next(state, 4000) == nil
    refute StatusSync.pending?(state)
    assert hd(StatusSync.view(state, %{"production_ready" => "Ready for production"}))["confirmed_at_ms"] == 2000
    assert {:error, :status_result_not_allowed} = result(state, op["id"], "sent")
  end

  test "closed commands, stale events and retry fences", c do
    assert {:error, _} = StatusSync.validate("status_transition", %{})
    assert {:error, _} = StatusSync.validate("status_result", %{})
    assert {:error, _} = StatusSync.validate("other", nil)
    assert {:error, _} = StatusSync.transition(c.state, command("reserve", G.task()))
    assert {:error, :review_not_ready} = StatusSync.transition(G.initial(), command("review_started", %{}))
    assert {:error, _} = StatusSync.validate("status_transition", command("review_started", %{"x" => 1})["args"])
    assert {:error, _} = result(c.state, "missing", "confirmed")
    assert {:error, :invalid_status_result} = StatusSync.result(c.state, %{})
    assert {:error, :status_transition_not_allowed} = StatusSync.transition(Map.put(c.state, "status_sync", List.duplicate(c.op, 256)), command("block", %{"reason" => "full"}))
    cancelling = G.apply!(G.initial(), "request_cancel", G.operator())
    assert {:error, :status_transition_not_allowed} = StatusSync.transition(cancelling, command("block", %{"reason" => "already cancelling"}))
    assert StatusSync.operations(nil) == []
    assert {:ok, sent} = result(c.state, c.op["id"], "sent")
    assert {:error, _} = result(sent, c.op["id"], "sent")
    assert {:ok, retry} = result(sent, c.op["id"], "retry")
    refute hd(StatusSync.operations(retry))["sent"]
    assert StatusSync.next(retry, 2999) == nil
    assert StatusSync.next(retry, 3000)
    assert {:ok, conflict} = result(sent, c.op["id"], "conflict")
    assert StatusSync.next(conflict, 9999) == nil
    assert StatusSync.pending?(conflict)
    stale = put_in(c.state, ["cycle", "work", "base_sha"], G.sha("f"))
    refute StatusSync.current?(stale, c.op)
    assert Remote.step(c.config, %{c.context | state: stale}, c.op, fn _ -> flunk("stale write") end, c.opts).status == "superseded"
  end

  test "controller events derive roles from valid lifecycle transitions" do
    ci_passed = G.initial() |> G.apply!("reserve_ci", G.ci_request()) |> G.apply!("observe_ci", G.ci_result())

    for {state, action, args, role} <- [
          {G.initial(), "start_work", %{"interval_id" => "w", "budget" => "initial"}, "working"},
          {G.initial() |> G.apply!("block", %{"reason" => "pause"}), "resume", Map.put(G.operator(), "sha", G.sha()), "working"},
          {G.reviewed(), "review_started", %{}, "review"},
          {G.reviewed(), "merged", %{"pr_number" => 7, "sha" => G.sha("c")}, "dev_validation"},
          {ci_passed, "handoff", %{"pr_number" => 7, "sha" => G.sha("b")}, "handoff"}
        ] do
      {_, op} = record(state, action, args)
      assert op["role"] == role
    end
  end

  test "status write has a durable send fence and readback; existing result never writes twice", c do
    parent = self()

    authorize = fn :sent ->
      send(parent, :authorized)
      :ok
    end

    assert %{status: "confirmed", observed: "Needs human decision"} = Remote.step(c.config, c.context, c.op, authorize, c.opts)
    assert_receive :authorized
    assert Agent.get(c.remote, & &1.writes) == 1
    assert %{status: "confirmed"} = Remote.step(c.config, c.context, %{c.op | "sent" => true}, fn _ -> flunk("duplicate") end, c.opts)
    assert Agent.get(c.remote, & &1.writes) == 1
  end

  test "lost mutation response is reconciled by readback, never blindly resent", c do
    Agent.update(c.remote, &%{&1 | after_failure: {:error, :closed}})
    assert %{status: "unknown"} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, c.opts)
    assert %{status: "confirmed"} = Remote.step(c.config, c.context, %{c.op | "sent" => true}, fn _ -> flunk("retry") end, c.opts)
    assert Agent.get(c.remote, & &1.writes) == 1
  end

  test "manual conflict, unknown outcome and revoked permission remain visible", c do
    assert %{status: "unknown"} = Remote.step(c.config, c.context, %{c.op | "sent" => true}, fn _ -> flunk("retry") end, c.opts)
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "state"], "Human review"))
    assert %{status: "conflict"} = Remote.step(c.config, c.context, c.op, fn _ -> flunk("overwrite") end, c.opts)
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "state"], "Agent working"))
    Agent.update(c.remote, &%{&1 | failure: {:ok, %{status: 403, headers: %{}, body: ""}}})
    assert %{status: "failed", error: "status_permission_denied"} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, c.opts)
  end

  test "rate limits persist delay; read failure after sent cannot clear the send fence", c do
    Agent.update(c.remote, &%{&1 | failure: {:ok, %{status: 429, headers: %{"retry-after" => ["120"]}, body: ""}}})
    assert %{status: "retry", delay_ms: 120_000} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, c.opts)
    Agent.update(c.remote, &%{&1 | read_failure: {:error, {:github_projects_http, 429, 120}}})
    assert %{status: "unknown", delay_ms: 120_000} = Remote.step(c.config, c.context, %{c.op | "sent" => true}, fn _ -> flunk("retry") end, c.opts)
  end

  test "scope mismatch and missing configured role cannot write", c do
    assert %{status: "failed"} = Remote.step(c.config, c.context, %{c.op | "repo" => "Other/app"}, fn _ -> flunk("scope") end, c.opts)
    assert %{status: "failed"} = Remote.step(c.config, c.context, %{c.op | "role" => "absent"}, fn _ -> flunk("scope") end, c.opts)
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "archived"], true))
    assert %{status: "failed", error: "status_scope_changed"} = Remote.step(c.config, c.context, c.op, fn _ -> flunk("archived") end, c.opts)
  end

  test "transient reads, bounded retries and malformed mutation responses fail conservatively", c do
    for {response, status, error} <- [
          {{:ok, %{status: 422}}, "failed", "status_write_refused"},
          {F.ok(%{"data" => %{}}), "unknown", "status_request_unconfirmed"},
          {{:error, :timeout}, "unknown", "status_request_unconfirmed"}
        ] do
      Agent.update(c.remote, &%{&1 | failure: response})
      assert %{status: ^status, error: ^error} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, c.opts)
    end

    assert %{status: "failed", error: "status_retry_exhausted"} = Remote.step(c.config, c.context, %{c.op | "attempts" => 3}, fn _ -> flunk("exhausted") end, c.opts)
    assert %{status: "failed", error: "status_reconciliation_exhausted"} = Remote.step(c.config, c.context, %{c.op | "checks" => 10}, fn _ -> flunk("exhausted") end, c.opts)
    Agent.update(c.remote, &%{&1 | read_failure: {:error, :timeout}})
    assert %{status: "retry", delay_ms: 30_000} = Remote.step(c.config, c.context, c.op, fn _ -> flunk("no read") end, c.opts)
  end

  test "status changing during evidence collection or after mutation is never silently accepted", c do
    reader = c.opts[:project_reader]

    opts =
      Keyword.put(c.opts, :project_reader, fn tracker, options ->
        {:ok, report} = reader.(tracker, options)
        if Agent.get(c.remote, & &1.calls) == 2, do: {:ok, put_in(report, ["items", Access.at(0), "state"], "Human review")}, else: {:ok, report}
      end)

    assert %{status: "conflict", error: "status_manually_changed"} = Remote.step(c.config, c.context, c.op, fn _ -> flunk("changed") end, opts)
    Agent.update(c.remote, &%{&1 | calls: 0})

    opts =
      Keyword.put(c.opts, :project_reader, fn tracker, options ->
        {:ok, report} = reader.(tracker, options)
        if Agent.get(c.remote, & &1.calls) == 3, do: {:ok, put_in(report, ["items", Access.at(0), "state"], "Human review")}, else: {:ok, report}
      end)

    assert %{status: "conflict", error: "status_readback_changed"} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, opts)
    assert Agent.get(c.remote, & &1.writes) == 1
  end

  test "readback outage preserves uncertainty and controller revocation prevents all writes", c do
    assert %{status: "retry"} = Remote.step(c.config, c.context, c.op, fn _ -> {:error, :status_send_revoked} end, c.opts)
    assert Agent.get(c.remote, & &1.writes) == 0
    writer = c.opts[:http]

    opts =
      Keyword.put(c.opts, :http, fn options ->
        response = writer.(options)
        Agent.update(c.remote, &%{&1 | read_failure: {:error, {:github_projects_http, 429, 120}}})
        response
      end)

    assert %{status: "unknown", error: "status_readback_unconfirmed"} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, opts)
    assert Agent.get(c.remote, & &1.writes) == 1
  end

  test "working requires current dev and Agent allowed, while blocking does not require permission to run", c do
    {state, op} = record(G.initial(), "start_work", %{"interval_id" => "w", "budget" => "initial"}, "Ready for agent")
    context = %{c.context | state: state}
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "state"], "Ready for agent"))
    writer = c.opts[:http]

    opts =
      Keyword.put(c.opts, :http, fn options ->
        if options[:method] == :get, do: F.ok(%{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => G.sha()}}), else: writer.(options)
      end)

    assert %{status: "confirmed"} = Remote.step(c.config, context, op, fn _ -> :ok end, opts)
    bad = Keyword.put(opts, :http, fn _ -> F.ok(%{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => G.sha("f")}}) end)
    assert %{status: "conflict", error: "status_evidence_changed"} = Remote.step(c.config, context, op, fn _ -> flunk("base changed") end, bad)
    unavailable = Keyword.put(opts, :http, fn _ -> {:error, :timeout} end)
    assert %{status: "retry"} = Remote.step(c.config, context, op, fn _ -> flunk("dev unknown") end, unavailable)
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "native_ref", "agent_allowed_option_id"], "no"))
    assert %{status: "failed", error: "status_scope_changed"} = Remote.step(c.config, context, op, fn _ -> flunk("revoked") end, opts)
    assert %{status: "confirmed"} = Remote.step(c.config, c.context, c.op, fn _ -> :ok end, c.opts)
  end

  test "review requires exact CI head and base plus native issue linkage; observation outage can retry", c do
    {state, op} = record(G.reviewed(), "review_started", %{}, "PR ready")
    context = %{c.context | state: state}
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "state"], "PR ready"))
    pr = %{"state" => "open", "number" => 7, "head_sha" => G.sha("b")}
    facts = %{"dev_sha" => G.sha(), "pr" => pr, "ci" => %{"result" => "success", "head_sha" => G.sha("b"), "base_sha" => G.sha()}}
    observer = fn _, options -> {:ok, Observation.new(c.settings, options[:context], facts, [])} end
    writer = c.opts[:http]

    opts =
      Keyword.merge(c.opts,
        observer: observer,
        http: fn options ->
          cond do
            options[:method] == :get -> F.ok([%{"id" => 7, "number" => 7, "node_id" => "pr-node"}])
            options[:json]["query"] =~ "SymphonyPublicationIssue" -> issue_response([%{"id" => "pr-node"}])
            true -> writer.(options)
          end
        end
      )

    assert %{status: "confirmed"} = Remote.step(c.config, context, op, fn _ -> :ok end, opts)
    bad = Keyword.put(opts, :http, fn _ -> issue_response([]) end)
    assert %{status: "retry"} = Remote.step(c.config, context, op, fn _ -> flunk("unconfirmed pulls") end, bad)
    bad = Keyword.put(opts, :http, fn options -> if options[:method] == :get, do: F.ok([]), else: issue_response([]) end)
    assert %{status: "conflict", error: "status_linkage_changed"} = Remote.step(c.config, context, op, fn _ -> flunk("no link") end, bad)
    bad = Keyword.put(opts, :observer, fn _, options -> {:ok, Observation.new(c.settings, options[:context], put_in(facts, ["ci", "base_sha"], G.sha("f")), [])} end)
    assert %{status: "conflict", error: "status_evidence_changed"} = Remote.step(c.config, context, op, fn _ -> flunk("stale CI") end, bad)
    bad = Keyword.put(opts, :observer, fn _, _ -> {:error, {:github_delivery_limited, 90}} end)
    assert %{status: "retry", delay_ms: 90_000} = Remote.step(c.config, context, op, fn _ -> flunk("outage") end, bad)
  end

  defp issue_response(links) do
    F.ok(%{
      "data" => %{
        "node" => %{
          "id" => "issue-A",
          "state" => "OPEN",
          "repository" => %{"nameWithOwner" => "ExampleOrg/app"},
          "comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
          "closedByPullRequestsReferences" => %{"nodes" => links, "pageInfo" => %{"hasNextPage" => false}}
        }
      }
    })
  end

  test "post-completion sync requires fresh deployment matching saved validation", c do
    {state, op} = record(G.ready(), "complete", G.proof("c"), "Dev validation")
    context = %{c.context | state: state}
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "state"], "Dev validation"))
    facts = %{"pr" => %{"state" => "merged", "number" => 7, "merge_sha" => G.sha("c"), "ancestry" => "included"}, "dev_sha" => G.sha("c"), "deployment" => G.deployment()}
    observer = fn _, opts -> {:ok, Observation.new(c.settings, opts[:context], facts, [])} end
    opts = Keyword.put(c.opts, :observer, observer)
    assert %{status: "confirmed"} = Remote.step(c.config, context, op, fn _ -> :ok end, opts)
    Agent.update(c.remote, &put_in(&1, [:report, "items", Access.at(0), "issue_state"], "CLOSED"))
    assert %{status: "confirmed"} = Remote.step(c.config, context, op, fn _ -> flunk("already accepted") end, opts)
    bad = fn _, opts -> {:ok, Observation.new(c.settings, opts[:context], put_in(facts, ["deployment", "run_attempt"], 2), [])} end
    assert %{status: "conflict", error: "status_evidence_changed"} = Remote.step(c.config, context, op, fn _ -> flunk("stale") end, Keyword.put(opts, :observer, bad))
  end

  test "seven roles are explicit, unique and inactive; changing the map changes the store scope", c do
    legacy = F.fixture()
    assert map_size(legacy.settings.project.states) == 4
    refute c.settings.gate.scope == legacy.settings.gate.scope
    roles = c.settings.project.states

    for invalid <- [Map.delete(roles, "review"), Map.put(roles, "review", roles["working"]), Map.put(roles, "review", "Done")] do
      raw = put_in(legacy.raw, ["tracker", "provider", "states"], invalid)
      {:ok, config} = Schema.parse(raw)
      assert {:error, _} = Config.delivery_observer_settings(config)
    end
  end
end
