defmodule SymphonyElixir.PublicationStateTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.DeliveryGate.{Command, Effects, Snapshot, State}
  alias SymphonyElixir.DeliveryGateSupport, as: G

  defp working, do: G.initial() |> G.apply!("start_work", %{"interval_id" => "w", "budget" => "initial"})

  defp request(kind \\ "publish"),
    do: %{
      "operation_id" => "op",
      "kind" => kind,
      "payload" => if(kind == "publish", do: %{"sha" => G.sha("b"), "title" => "Feature", "body" => "Report"}, else: if(kind == "start", do: %{}, else: %{"body" => "Report"}))
    }

  defp stopped(state), do: G.apply!(state, "stop_work", %{"interval_id" => "w", "elapsed_ms" => 25})
  defp sent(state, step), do: G.apply!(state, "effect_sent", %{"operation_id" => "op", "step" => step})
  defp confirm(state, step, result \\ %{}), do: G.apply!(state, "effect_confirm", %{"operation_id" => "op", "step" => step, "result" => result})

  test "publication is prepared, stopped, reserved and linked before handoff; unknown effects prevent completion" do
    state = working() |> G.apply!("effect_request", request())
    assert {:ok, ^state} = State.apply_command(state, "effect_request", request())
    assert {:error, :effect_id_reused} = State.apply_command(state, "effect_request", request("report"))
    assert {:error, :effect_in_progress} = State.apply_command(state, "effect_request", Map.put(request("report"), "operation_id", "other"))
    assert {:error, :effect_send_not_allowed} = State.apply_command(state, "effect_sent", %{"operation_id" => "op", "step" => "push"})
    state = state |> G.apply!("effect_submit", %{"operation_id" => "op"}) |> stopped()
    assert {:error, :work_unresolved} = State.admission(state, "item-A")
    state = state |> G.apply!("reserve_ci", G.ci_request()) |> sent("push")
    assert {:error, :effect_send_not_allowed} = State.apply_command(state, "effect_sent", %{"operation_id" => "op", "step" => "push"})
    assert {:error, :effect_send_not_allowed} = State.apply_command(state, "effect_sent", %{"operation_id" => "op", "step" => "link"})
    state = state |> confirm("push") |> sent("pull") |> confirm("pull", %{"pr_number" => 7}) |> G.apply!("bind_pr", %{"pr_number" => 7, "sha" => G.sha("b")})
    assert state["cycle"]["work"]["pr_number"] == 7
    assert {:error, :effect_send_not_allowed} = State.apply_command(state, "effect_sent", %{"operation_id" => "op", "step" => "comment"})
    assert {:error, :pr_binding_not_allowed} = State.apply_command(state, "bind_pr", %{"pr_number" => 8, "sha" => G.sha("b")})
    state = G.apply!(state, "observe_ci", G.ci_result())
    assert {:error, :work_unresolved} = State.apply_command(state, "handoff", %{"pr_number" => 7, "sha" => G.sha("b")})
    state = Enum.reduce(~w(comment link status), state, fn step, acc -> acc |> sent(step) |> confirm(step) end)
    assert {:ok, ^state} = State.apply_command(state, "effect_confirm", %{"operation_id" => "op", "step" => "status", "result" => %{}})
    state = G.apply!(state, "handoff", %{"pr_number" => 7, "sha" => G.sha("b")})
    assert state["cycle"]["phase"] == "awaiting_review"
    refute Effects.unresolved?(state["cycle"])
  end

  test "cancellation retains an unknown write and rejects another write" do
    state = working() |> G.apply!("effect_request", request("report")) |> sent("comment") |> G.apply!("request_cancel", G.operator())
    assert Effects.unresolved?(state["cycle"])
    assert Effects.sent?(state["cycle"])
    assert {:error, :effect_send_not_allowed} = State.apply_command(state, "effect_sent", %{"operation_id" => "op", "step" => "comment"})
    state = confirm(state, "comment")
    refute Effects.unresolved?(state["cycle"])
    assert state["cycle"]["phase"] == "cancelling"
    assert {:error, :effect_not_allowed} = State.apply_command(state, "effect_request", Map.put(request(), "operation_id", "new"))
  end

  test "candidate is immutable and unknown transitions fail closed" do
    state = working() |> G.apply!("effect_request", request())
    proof = %{"operation_id" => "op", "digest" => String.duplicate("a", 64), "base_sha" => G.sha()}
    state = G.apply!(state, "effect_candidate", proof)
    assert {:error, :candidate_changed} = State.apply_command(state, "effect_candidate", Map.put(proof, "base_sha", G.sha("c")))
    assert {:error, :unknown_effect} = State.apply_command(state, "effect_submit", %{"operation_id" => "missing"})
    assert {:error, :effect_confirmation_not_allowed} = State.apply_command(state, "effect_confirm", %{"operation_id" => "op", "step" => "merge", "result" => %{}})
    assert {:error, :invalid_command_arguments} = Command.validate("effect_candidate", Map.put(proof, "digest", "bad"))
    assert {:error, :invalid_command_arguments} = Command.validate("effect_request", Map.put(request(), "repo", "other/repo"))
    oversized = put_in(request(), ["payload", "body"], String.duplicate("x", 16_001))
    assert {:error, :invalid_command_arguments} = Command.validate("effect_request", oversized)
    assert {:error, :invalid_command_arguments} = Command.validate("effect_sent", %{})
    assert {:error, :invalid_command_arguments} = Command.validate("effect_confirm", %{"operation_id" => "op", "step" => "push", "result" => nil})
    refute Effects.payload?("merge", %{})
    assert {:error, :invalid_command_arguments} = Command.validate("effect_confirm", nil)
  end

  test "manual rerun over limit remains blocked, and unsettled attempts are never refunded" do
    state = G.initial() |> G.apply!("reserve_ci", G.ci_request()) |> G.apply!("observe_ci", G.ci_result("ci-1", "pending"))
    result = %{"run_id" => 100, "run_attempt" => 2, "sha" => G.sha("b"), "result" => "failure"}
    assert {:error, :ci_unresolved} = State.apply_command(state, "manual_ci", result)
    state = G.apply!(state, "observe_ci", G.ci_result("ci-1", "failure"))
    state = G.apply!(state, "manual_ci", result)
    state = G.apply!(state, "manual_ci", Map.put(result, "run_attempt", 3))
    state = G.apply!(state, "manual_ci", Map.put(result, "run_attempt", 4))
    assert state["cycle"]["block_reason"] == "retry_budget_exhausted"
    state = working() |> G.apply!("effect_request", request()) |> G.apply!("effect_submit", %{"operation_id" => "op"}) |> stopped()
    state = state |> G.apply!("reserve_ci", G.ci_request()) |> sent("push") |> G.apply!("observe_ci", G.ci_result("ci-1", "failure"))
    assert {:error, :publication_unresolved} = State.apply_command(state, "begin_fix", %{})
  end

  test "manual rerun binds a new attempt without resetting budgets or allowing a new workflow" do
    state = G.initial() |> G.apply!("reserve_ci", G.ci_request()) |> G.apply!("observe_ci", G.ci_result("ci-1", "failure"))
    result = %{"run_id" => 100, "run_attempt" => 2, "sha" => G.sha("b"), "result" => "pending"}
    assert {:error, :manual_ci_not_allowed} = State.apply_command(state, "manual_ci", Map.put(result, "run_id", 999))
    state = G.apply!(state, "manual_ci", result)
    assert state["cycle"]["budget"]["ci_floor"] == 2
    assert state["cycle"]["budget"]["retry_floor"][G.sha("b")] == 1
    assert {:error, :manual_ci_not_allowed} = State.apply_command(state, "manual_ci", result)
    state = G.apply!(state, "observe_ci", G.ci_result("manual-100-2", "success", 2))
    assert {:ok, state} = State.apply_command(state, "handoff", %{"pr_number" => 7, "sha" => G.sha("b")})
    assert state["cycle"]["phase"] == "awaiting_review"
  end

  test "outbox survives deterministic snapshot replay" do
    snapshot = Snapshot.new(%{})

    commands = [
      {"bootstrap", G.validation()},
      {"reserve", G.task()},
      {"start_work", %{"interval_id" => "w", "budget" => "initial"}},
      {"effect_request", request("report")},
      {"effect_sent", %{"operation_id" => "op", "step" => "comment"}}
    ]

    snapshot =
      Enum.with_index(commands)
      |> Enum.reduce(snapshot, fn {{action, args}, i}, snap ->
        {:ok, next, :new} = Snapshot.append(snap, "cmd-#{i}", i, action, args, i)
        next
      end)

    assert {:ok, ^snapshot} = Snapshot.decode(snapshot, %{})
    assert Effects.sent?(snapshot["state"]["cycle"])
    assert {:error, :invalid_snapshot} = Snapshot.decode(put_in(snapshot, ["state", "cycle", "effects", "op", "steps"], %{}), %{})
  end
end
