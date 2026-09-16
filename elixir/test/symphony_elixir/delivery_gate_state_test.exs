defmodule SymphonyElixir.DeliveryGateStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DeliveryGate.{Budget, Command, Snapshot, State}
  import SymphonyElixir.DeliveryGateSupport

  test "bootstrap is explicit and owner persists through handoff, merge and validation" do
    assert {:error, :cycle_blocked} = State.admission(State.new(), "new")
    assert {:error, :no_active_cycle} = State.apply_command(State.new(), "reserve", task())
    assert :ok = State.admission(initial(), "item-A")
    assert {:error, :cycle_blocked} = State.admission(reviewed(), "new")
    assert {:error, :cycle_not_complete} = State.apply_command(merged(), "complete", proof("c"))
    assert {:error, :cycle_not_complete} = State.apply_command(ready(), "complete", proof("d"))
    completed = apply!(ready(), "complete", proof("c"))
    assert :ok = State.admission(completed, "new")
    assert completed["last_cycle"]["owner"]["item_id"] == "item-A"
    assert completed["last_cycle"]["phase"] == "completed"
    assert {:error, :unvalidated_base} = State.apply_command(completed, "reserve", task())
    assert {:ok, _} = State.apply_command(completed, "reserve", %{task() | "cycle_id" => "cycle-B", "sha" => sha("c")})
  end

  test "unknown commands, arbitrary metadata and invalid identities cannot enter the journal" do
    assert {:error, :unknown_command} = Command.validate("mark_done", %{})
    assert {:error, :invalid_command_arguments} = Command.validate("block", %{"reason" => "x", "token" => "secret"})
    assert {:error, :invalid_command_arguments} = Command.validate("block", nil)

    for bad <- ["", " ", nil, 3, String.duplicate("x", 2049)] do
      assert {:error, :invalid_command_arguments} = Command.validate("block", %{"reason" => bad})
    end

    for branch <- ["dev", "main", "agent/x..y", "agent/a//b", "agent/end/", "agent/a.lock", "agent/a b"] do
      assert {:error, _} = Command.validate("reserve", %{task() | "branch" => branch})
    end

    for {key, value} <- [{"sha", "bad"}, {"run_id", 0}, {"run_attempt", -1}, {"criteria", []}, {"criteria", [""]}] do
      assert {:error, _} = Command.validate("bootstrap", Map.put(validation(), key, value))
    end

    assert {:error, _} = Command.validate("observe_ci", %{ci_result() | "result" => "neutral"})
    assert {:error, _} = Command.validate("reserve_ci", %{ci_request() | "retry" => "yes"})
  end

  test "budgets reserve before use and separate original work from fixes" do
    state = apply!(initial(), "start_work", %{"interval_id" => "session-1", "budget" => "initial"})
    assert {:error, :invalid_phase} = State.apply_command(state, "start_work", %{"interval_id" => "other", "budget" => "initial"})
    state = apply!(state, "checkpoint", %{"interval_id" => "session-1", "elapsed_ms" => 10_000})
    state = apply!(state, "checkpoint", %{"interval_id" => "session-1", "elapsed_ms" => 10_000})
    assert state["cycle"]["budget"]["initial_ms"] == 10_000
    assert {:error, :elapsed_time_regressed} = State.apply_command(state, "checkpoint", %{"interval_id" => "session-1", "elapsed_ms" => 9_999})
    state = apply!(state, "stop_work", %{"interval_id" => "session-1", "elapsed_ms" => 3_600_000})
    assert state["cycle"]["budget"]["fix_ms"] == 0
    refute state["cycle"]["budget"]["accounting_uncertain"]
    exhausted = apply!(state, "start_work", %{"interval_id" => "session-2", "budget" => "initial"})
    assert exhausted["cycle"]["phase"] == "needs_human_decision"
    assert {:error, :wrong_time_budget} = State.apply_command(initial(), "start_work", %{"interval_id" => "s", "budget" => "fix"})
  end

  test "a live interval can exceed its budget but always records actual consumed time and blocks" do
    state = initial() |> apply!("start_work", %{"interval_id" => "s", "budget" => "initial"})
    state = apply!(state, "checkpoint", %{"interval_id" => "s", "elapsed_ms" => 3_600_001})
    assert state["cycle"]["phase"] == "needs_human_decision"
    assert state["cycle"]["budget"]["initial_ms"] == 3_600_001
    resolved = apply!(state, "resolve_interval", Map.merge(operator(), %{"interval_id" => "s", "elapsed_ms" => 3_601_000}))
    assert resolved["cycle"]["budget"]["interval"] == nil
    assert resolved["cycle"]["budget"]["accounting_uncertain"]
    assert resolved["cycle"]["phase"] == "needs_human_decision"
    assert {:error, :unknown_interval} = State.apply_command(resolved, "stop_work", %{"interval_id" => "s", "elapsed_ms" => 3_601_000})
  end

  test "two retries per SHA retain all original reservations and failed attempts" do
    state = initial() |> apply!("reserve_ci", ci_request())
    assert {:error, :ci_unresolved} = State.apply_command(state, "reserve_ci", ci_request("ci-2", "b", true))
    state = state |> apply!("observe_ci", ci_result("ci-1", "failure"))
    assert {:error, :same_sha_requires_retry} = State.apply_command(state, "reserve_ci", ci_request("ci-2"))
    state = state |> apply!("reserve_ci", ci_request("ci-2", "b", true)) |> apply!("observe_ci", ci_result("ci-2", "failure", 2))
    state = state |> apply!("reserve_ci", ci_request("ci-3", "b", true)) |> apply!("observe_ci", ci_result("ci-3", "failure", 3))
    blocked = apply!(state, "reserve_ci", ci_request("ci-4", "b", true))
    assert map_size(blocked["cycle"]["budget"]["ci"]) == 3
    assert blocked["cycle"]["block_reason"] == "retry_budget_exhausted"
  end

  test "the sixth successful CI is accepted, the seventh needs a budget extension" do
    state =
      Enum.reduce(1..6, initial(), fn n, state ->
        id = "ci-#{n}"
        letter = Enum.at(~w(a b c d e f), n - 1)
        state |> apply!("reserve_ci", ci_request(id, letter)) |> apply!("observe_ci", ci_result(id, "success", n))
      end)

    assert {:ok, _} = State.apply_command(state, "handoff", %{"pr_number" => 7, "sha" => sha("f")})
    blocked = apply!(state, "reserve_ci", ci_request("ci-7", "1"))
    assert blocked["cycle"]["block_reason"] == "ci_budget_exhausted"
    extension = Map.merge(operator(), %{"initial_ms" => 10_000, "fix_ms" => 0, "fixes" => 0, "ci_attempts" => 1, "retries_per_sha" => 0})
    extended = blocked |> apply!("extend_budget", extension) |> apply!("resume", Map.put(operator(), "sha", sha()))
    assert map_size(extended["cycle"]["budget"]["ci"]) == 6
    assert length(extended["cycle"]["budget"]["extensions"]) == 1
    assert {:ok, _} = State.apply_command(extended, "reserve_ci", ci_request("ci-7", "1"))
  end

  test "only latest successful CI can enter review and a new attempt invalidates an older success" do
    state = initial() |> apply!("reserve_ci", ci_request()) |> apply!("observe_ci", ci_result())
    state = state |> apply!("reserve_ci", ci_request("ci-2", "b", true)) |> apply!("observe_ci", ci_result("ci-2", "failure", 2))
    assert {:error, :ci_not_successful} = State.apply_command(state, "handoff", %{"pr_number" => 7, "sha" => sha("b")})
    assert {:error, :ci_result_changed} = State.apply_command(state, "observe_ci", ci_result("ci-2", "success", 2))
    assert {:error, :reservation_run_changed} = State.apply_command(state, "observe_ci", ci_result("ci-2", "failure", 3))
    assert {:error, :unknown_reservation} = State.apply_command(state, "observe_ci", ci_result("unknown"))
  end

  test "fixes are counted as cycles, not commits, and share a distinct cumulative time budget" do
    state =
      Enum.reduce(1..2, initial(), fn n, state ->
        id = "ci-#{n}"

        state
        |> apply!("reserve_ci", ci_request(id, if(n == 1, do: "b", else: "c")))
        |> apply!("observe_ci", ci_result(id, "failure", n))
        |> apply!("begin_fix")
        |> apply!("start_work", %{"interval_id" => "fix-#{n}", "budget" => "fix"})
        |> apply!("stop_work", %{"interval_id" => "fix-#{n}", "elapsed_ms" => 1000})
      end)

    assert state["cycle"]["budget"]["fix_ms"] == 2000
    state = state |> apply!("reserve_ci", ci_request("ci-3", "d")) |> apply!("observe_ci", ci_result("ci-3", "failure", 3))
    blocked = apply!(state, "begin_fix")
    assert blocked["cycle"]["block_reason"] == "fix_budget_exhausted"
    assert blocked["cycle"]["budget"]["initial_ms"] == 0
  end

  test "manual runs are deduplicated separately and cannot replenish automatic budgets" do
    run = %{"run_id" => 1, "run_attempt" => 1, "sha" => sha()}
    state = initial() |> apply!("external_ci", run) |> apply!("external_ci", run)
    assert map_size(state["cycle"]["budget"]["external_ci"]) == 1
    assert state["cycle"]["budget"]["ci"] == %{}
    assert {:error, :external_run_changed} = State.apply_command(state, "external_ci", %{run | "sha" => sha("b")})
  end

  test "a newer deployment attempt clears manual validation; inherited queue pause blocks readiness" do
    state = ready() |> apply!("deployment", deployment("c", 2))
    assert state["cycle"]["validation"] == nil
    assert {:error, :validation_not_current} = State.apply_command(state, "validate_dev", passed())
    paused = apply!(state, "deployment", %{deployment("c", 2) | "environment_ready" => false})
    assert paused["cycle"]["block_reason"] == "environment_not_ready"
    assert {:error, :validation_not_current} = State.apply_command(paused, "validate_dev", passed("c", 2))
    failed = apply!(state, "validate_dev", %{passed("c", 2) | "passed" => false})
    assert failed["cycle"]["block_reason"] == "manual_validation_failed"
    assert {:error, :cycle_not_complete} = State.apply_command(failed, "complete", proof("c", 2))
  end

  test "operator cancellation requires stopped work and fresh validation after merge" do
    running = initial() |> apply!("start_work", %{"interval_id" => "s", "budget" => "initial"})
    cancelling = apply!(running, "request_cancel", operator())
    assert {:error, :work_unresolved} = State.apply_command(cancelling, "finish_cancel", validation())
    stopped = apply!(cancelling, "stop_work", %{"interval_id" => "s", "elapsed_ms" => 15_000})
    closed = apply!(stopped, "finish_cancel", validation())
    assert closed["last_cycle"]["budget"]["initial_ms"] == 15_000
    assert closed["last_cycle"]["phase"] == "cancelled"
    assert :ok = State.admission(closed, "new")
    after_merge = apply!(merged(), "request_cancel", operator())
    assert {:error, :merged_environment_unvalidated} = State.apply_command(after_merge, "finish_cancel", validation("c"))
    after_merge = after_merge |> apply!("deployment", deployment()) |> apply!("validate_dev", passed())
    assert after_merge["cycle"]["phase"] == "cancelling"
    assert {:ok, _} = State.apply_command(after_merge, "finish_cancel", validation("c"))
    assert {:error, :cancellation_not_requested} = State.apply_command(ready(), "finish_cancel", validation("c"))
  end

  test "approved recovery preserves the primary cycle and never admits another ordinary task" do
    blocked = apply!(merged(), "deployment", %{deployment() | "result" => "failure"})
    recovering = apply!(blocked, "assign_recovery", recovery())
    assert recovering["cycle"]["owner"]["item_id"] == "item-A"
    assert recovering["cycle"]["task"]["item_id"] == "item-R"
    assert recovering["cycle"]["suspended"]["budget"] == blocked["cycle"]["budget"]
    assert :ok = State.admission(recovering, "item-R")
    assert {:error, :cycle_blocked} = State.admission(recovering, "item-A")
    assert {:error, :cycle_blocked} = State.admission(recovering, "new")

    recovered =
      recovering
      |> apply!("reserve_ci", ci_request("recovery-ci", "d"))
      |> apply!("observe_ci", ci_result("recovery-ci"))
      |> apply!("handoff", %{"pr_number" => 8, "sha" => sha("d")})
      |> apply!("merged", %{"pr_number" => 8, "sha" => sha("e")})
      |> apply!("deployment", deployment("e"))
      |> apply!("validate_dev", passed("e"))

    assert {:error, :cycle_not_complete} = State.apply_command(recovered, "complete", proof("e"))
    cancelled = apply!(recovered, "request_cancel", operator())
    assert {:error, :recovery_not_complete} = State.apply_command(cancelled, "finish_recovery", proof("e"))
    assert {:ok, _} = State.apply_command(cancelled, "finish_cancel", validation("e"))
    complete = apply!(recovered, "finish_recovery", proof("e"))
    assert complete["last_cycle"]["phase"] == "recovered"
    assert complete["last_cycle"]["suspended"]["work"]["pr_number"] == 7
  end

  test "cancelling recovery restores the blocked owner, not a free repository" do
    state = merged() |> apply!("block", %{"reason" => "dev_changed"}) |> apply!("assign_recovery", recovery())
    state = state |> apply!("request_cancel", operator()) |> apply!("finish_cancel", validation("c"))
    assert state["cycle"]["task"]["item_id"] == "item-A"
    assert state["cycle"]["block_reason"] == "recovery_cancelled"
    assert {:error, :cycle_blocked} = State.admission(state, "new")
  end

  test "operator can resolve a definitely unsent CI reservation without refunding its budget" do
    state = initial() |> apply!("reserve_ci", ci_request()) |> apply!("request_cancel", operator())
    assert {:error, :work_unresolved} = State.apply_command(state, "finish_cancel", validation())
    state = apply!(state, "confirm_ci_not_started", Map.put(operator(), "reservation_id", "ci-1"))
    assert state["cycle"]["budget"]["ci_floor"] == 1
    assert map_size(state["cycle"]["budget"]["ci"]) == 1
    assert {:error, :ci_result_changed} = State.apply_command(state, "observe_ci", ci_result())
    missing = Map.put(operator(), "reservation_id", "missing")
    assert {:error, :ci_absence_not_confirmable} = State.apply_command(state, "confirm_ci_not_started", missing)
    assert {:ok, _} = State.apply_command(state, "finish_cancel", validation())
  end

  test "recovery before primary merge returns to the original task with its budget preserved" do
    blocked = reviewed() |> apply!("block", %{"reason" => "external_dev_failure"})

    state =
      blocked
      |> apply!("assign_recovery", recovery())
      |> apply!("reserve_ci", ci_request("r", "d"))
      |> apply!("observe_ci", ci_result("r"))
      |> apply!("handoff", %{"pr_number" => 8, "sha" => sha("d")})
      |> apply!("merged", %{"pr_number" => 8, "sha" => sha("e")})
      |> apply!("deployment", deployment("e"))
      |> apply!("validate_dev", passed("e"))
      |> apply!("finish_recovery", proof("e"))

    assert state["cycle"]["task"]["item_id"] == "item-A"
    assert state["cycle"]["work"]["pr_number"] == 7
    assert state["cycle"]["budget"] == blocked["cycle"]["budget"]
    assert state["cycle"]["block_reason"] == "base_reconciliation_required"
    assert {:error, :cycle_blocked} = State.admission(state, "new")
  end

  test "blocking a validated deployment invalidates the previous positive decision" do
    state = ready() |> apply!("block", %{"reason" => "environment_observation_unknown"})
    assert state["cycle"]["validation"] == nil
    assert {:error, :cycle_not_complete} = State.apply_command(state, "complete", proof("c"))
  end

  test "time and CI reservations cannot overlap a still-running interval" do
    running = initial() |> apply!("start_work", %{"interval_id" => "s", "budget" => "initial"})
    assert {:error, :worker_not_stopped} = Budget.apply_command(running["cycle"]["budget"], "begin_fix", %{})
    assert {:error, :worker_not_stopped} = Budget.apply_command(running["cycle"]["budget"], "reserve_ci", ci_request())
  end

  test "backup restoration cannot roll budgets back or mint retries after an extension" do
    state = initial() |> apply!("reserve_ci", ci_request()) |> apply!("observe_ci", ci_result("ci-1", "failure"))
    state = apply!(state, "record_restore", operator())
    budget = state["cycle"]["budget"]
    assert budget["ci_floor"] == 6
    assert budget["accounting_uncertain"]
    assert budget["initial_ms"] == 3_600_000
    assert state["cycle"]["block_reason"] == "restored_accounting_requires_operator"
    extension = Map.merge(operator(), %{"initial_ms" => 1000, "fix_ms" => 0, "fixes" => 0, "ci_attempts" => 2, "retries_per_sha" => 1})

    state =
      state
      |> apply!("extend_budget", extension)
      |> apply!("resume", Map.put(operator(), "sha", sha()))
      |> apply!("reserve_ci", ci_request("ci-2", "b", true))
      |> apply!("observe_ci", ci_result("ci-2", "failure", 2))

    state = apply!(state, "reserve_ci", ci_request("ci-3", "b", true))
    assert state["cycle"]["block_reason"] == "retry_budget_exhausted"
    assert state["cycle"]["budget"]["ci_floor"] == 7

    running =
      initial() |> apply!("start_work", %{"interval_id" => "s", "budget" => "initial"}) |> apply!("checkpoint", %{"interval_id" => "s", "elapsed_ms" => 1000}) |> apply!("record_restore", operator())

    restored = apply!(running, "resolve_interval", Map.merge(operator(), %{"interval_id" => "s", "elapsed_ms" => 1100}))
    assert restored["cycle"]["budget"]["initial_ms"] == 3_600_000
    assert restored["cycle"]["budget"]["interval"] == nil
  end

  test "snapshot validates its entire journal, scope and derived state without resetting counters" do
    scope = %{"repo" => "example/app"}
    snapshot = Snapshot.new(scope)
    assert {:ok, first, :new} = Snapshot.append(snapshot, "boot", 0, "bootstrap", validation(), 10)
    assert {:ok, second, :new} = Snapshot.append(first, "reserve", 1, "reserve", task(), 20)
    assert {:ok, ^second} = Snapshot.decode(Jason.decode!(Jason.encode!(second)), scope)
    assert {:ok, ^second, :replayed} = Snapshot.append(second, "boot", 0, "bootstrap", validation(), 30)
    assert {:error, :command_id_reused} = Snapshot.append(second, "boot", 0, "bootstrap", validation("b"), 30)
    assert {:error, :stale_revision} = Snapshot.append(second, "stale", 0, "block", %{"reason" => "x"}, 30)
    assert {:error, :invalid_command_identity} = Snapshot.append(second, "", 2, "block", %{"reason" => "x"}, 30)

    for corrupted <- [
          nil,
          %{},
          %{second | "schema_version" => 2},
          %{second | "revision" => 0},
          put_in(second, ["state", "cycle", "budget", "initial_ms"], 1),
          %{second | "commands" => [nil]},
          %{second | "commands" => second["commands"] ++ second["commands"]}
        ] do
      assert {:error, :invalid_snapshot} = Snapshot.decode(corrupted, scope)
    end

    assert {:error, :invalid_snapshot} = Snapshot.decode(second, %{"repo" => "another/app"})
    assert {:error, :invalid_snapshot} = Snapshot.decode(%{second | "commands" => List.duplicate(nil, 20_001)}, scope)
    assert {:error, :journal_full} = Snapshot.append(%{second | "commands" => List.duplicate(%{"id" => "old"}, 20_000)}, "new", 2, "block", %{"reason" => "x"}, 30)
  end

  test "malformed or unsafe operations never release an owner" do
    for {action, args} <- [
          {"bootstrap", validation()},
          {"handoff", %{"pr_number" => 1, "sha" => sha()}},
          {"merged", %{"pr_number" => 1, "sha" => sha()}},
          {"begin_fix", %{}},
          {"deployment", deployment()},
          {"finish_recovery", proof()},
          {"resume", Map.put(operator(), "sha", sha())},
          {"assign_recovery", recovery()}
        ] do
      assert {:error, _} = State.apply_command(initial(), action, args)
    end

    cancelling = apply!(initial(), "request_cancel", operator())
    assert {:error, :cancellation_already_requested} = State.apply_command(cancelling, "request_cancel", operator())
    assert {:ok, _} = State.apply_command(State.new(), "record_restore", operator())
    assert {:error, :work_unresolved} = State.admission(put_in(initial(), ["cycle", "budget", "interval"], %{}), "item-A")
    assert {:error, :worker_not_stopped} = Budget.apply_command(%{Budget.new() | "interval" => %{}}, "start_work", %{"budget" => "initial", "interval_id" => "s"})
  end
end
