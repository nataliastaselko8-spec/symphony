defmodule SymphonyElixir.LifecycleTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.DeliveryGate.{Command, Lifecycle, Snapshot, State, StatusSync}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.Operator.{Decision, Policy}

  defp settings do
    f = F.fixture()
    put_in(f.settings, [:project, :states], Map.merge(f.settings.project.states, %{"review" => "Human review", "dev_validation" => "Dev validation", "production_ready" => "Ready for production"}))
  end

  defp event(state, action, args) do
    {"lifecycle", wrapped} = Lifecycle.wrap(settings(), state, action, args, nil)
    command = %{"id" => "event-#{length(StatusSync.operations(state))}", "expected_revision" => length(StatusSync.operations(state)), "at_ms" => 1000, "args" => wrapped}
    assert :ok = Command.validate("lifecycle", wrapped)
    assert {:ok, next} = Lifecycle.apply(state, command)
    next
  end

  defp decision(kind, data \\ %{}), do: %{"kind" => kind, "actor" => "local:owner", "reason" => "Verified by owner", "data" => data, "request_hash" => Policy.hash({kind, data})}

  test "explicit lifecycle replay preserves old commands and never creates a historical final status" do
    snapshot = Snapshot.new(%{})
    {:ok, snapshot, :new} = Snapshot.append(snapshot, "boot", 0, "bootstrap", G.validation(), 1)
    {"lifecycle", args} = Lifecycle.wrap(settings(), snapshot["state"], "operator_decision", decision("pause"), nil)
    {:ok, snapshot, :new} = Snapshot.append(snapshot, "pause", 1, "lifecycle", args, 2)
    assert {:ok, ^snapshot} = Snapshot.decode(snapshot, %{})
    assert StatusSync.operations(snapshot["state"]) == []
    legacy = G.apply!(G.ready(), "complete", G.proof("c"))
    assert StatusSync.operations(event(legacy, "operator_decision", decision("pause"))) == []
    assert Lifecycle.wrap(F.fixture().settings, G.initial(), "block", %{"reason" => "failure"}, nil) == {"block", %{"reason" => "failure"}}
    assert {:error, _} = Command.validate("lifecycle", nil)
    assert {:error, _} = Command.validate("lifecycle", %{args | "action" => "lifecycle"})
    assert {:error, _} = Command.validate("lifecycle", Map.put(args, "target", "Done"))
  end

  test "budget exhaustion and pause are recorded with blocking; unpause never resumes work" do
    state = event(G.initial(), "start_work", %{"interval_id" => "w", "budget" => "initial"})
    limit = state["cycle"]["budget"]["interval"]["reserved_ms"]
    state = event(state, "checkpoint", %{"interval_id" => "w", "elapsed_ms" => limit})
    assert state["cycle"]["phase"] == "needs_human_decision"
    assert List.last(StatusSync.operations(state))["role"] == "blocked"
    paused = event(G.initial(), "operator_decision", decision("pause"))
    unpaused = event(paused, "operator_decision", decision("unpause"))
    refute Decision.held?(unpaused)
    assert unpaused["cycle"]["phase"] == "needs_human_decision"
    assert length(StatusSync.operations(unpaused)) == 1
    assert {:error, _} = State.apply_command(paused, "resume_delivery", Map.put(G.operator(), "sha", G.sha()))
  end

  test "review survives unrelated budget updates and a cancelled cycle cannot become production ready" do
    state = event(G.reviewed(), "operator_decision", decision("review_started"))
    limits = %{"initial_ms" => 1000, "fix_ms" => 0, "fixes" => 0, "ci_attempts" => 0, "retries_per_sha" => 0}
    state = event(state, "operator_decision", decision("extend_budget", limits))
    assert Enum.map(StatusSync.operations(state), & &1["role"]) == ["review"]
    cancelled = event(G.initial(), "operator_decision", decision("cancel"))
    cancelled = event(cancelled, "operator_decision", decision("finish_cancel", Map.put(G.proof(), "criteria", ["Checked absence of PR"])))
    assert cancelled["last_cycle"]["phase"] == "cancelled"
    assert Enum.all?(StatusSync.operations(cancelled), &(&1["role"] == "blocked"))
  end

  test "recheck remains a closed operator action and cannot confirm an absent operation" do
    assert {:error, _} = Decision.validate(decision("recheck_status", %{}))
    assert {:error, _} = Decision.apply(G.initial(), decision("recheck_status", %{"operation_id" => "missing"}))
    form = %{action: "recheck_status", id: "form", actor: "local:owner"}
    assert {:error, _} = Policy.build(form, %{"reason" => "check"}, nil, settings(), G.initial())
    obs = %{complete: true, reasons: [], facts: %{"deployment" => G.deployment("a"), "dev_sha" => G.sha()}}
    assert {:error, :status_result_not_allowed} = Policy.build(form, %{"reason" => "check"}, obs, settings(), G.initial())
  end
end
