defmodule SymphonyElixir.DeliveryRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGate.{Budget, Effects}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.Observation
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    config = put_in(F.fixture().config.delivery.state_path, Path.join(root, "state.json")).config
    {:ok, settings} = Config.delivery_observer_settings(config)
    gate = start_supervised!({DeliveryGate, settings: settings.gate})
    tasks = start_supervised!(Task.Supervisor)
    clock = start_supervised!({Agent, fn -> 0 end})

    observer = fn _, opts ->
      context = Keyword.fetch!(opts, :context)
      {:ok, Observation.new(settings, context, facts(), ["manual_dev_validation_required"])}
    end

    opts = [config: config, gate: gate, task_supervisor: tasks, now: fn -> Agent.get(clock, & &1) end, observer: observer, watch: fn _, _, _, _ -> :ok end, checkpoint_ms: 100_000]
    %{root: root, gate: gate, tasks: tasks, clock: clock, config: config, settings: settings, opts: Keyword.put(opts, :poll_ms, 0)}
  end

  defp facts, do: %{"project" => %{"items" => [row("A"), row("B")]}, "dev_sha" => G.sha(), "deployment" => G.deployment("a"), "watch_digest" => String.duplicate("a", 64)}

  defp row(letter),
    do: %{
      "item_id" => "item-" <> letter,
      "state" => "Ready for agent",
      "eligible" => true,
      "archived" => false,
      "issue_state" => "OPEN",
      "native_ref" => %{"issue_id" => "issue-" <> letter, "repo" => "ExampleOrg/app"}
    }

  defp issue(letter \\ "A"),
    do: %Issue{
      id: "item-" <> letter,
      identifier: "GHP-" <> Base.encode16("item-" <> letter, case: :lower),
      title: "Task",
      state: "Ready for agent",
      dispatchable: true,
      native_ref: row(letter)["native_ref"]
    }

  defp await(runtime, predicate, attempts \\ 200)
  defp await(_, _, 0), do: flunk("runtime did not reach the expected state")

  defp await(runtime, predicate, attempts) do
    state = DeliveryRuntime.status(runtime)

    if predicate.(state),
      do: state,
      else:
        (
          Process.sleep(10)
          await(runtime, predicate, attempts - 1)
        )
  end

  defp ready(runtime), do: await(runtime, &(&1.observation != nil and &1.gate.mode == :reconciled))

  defp boot(c, overrides \\ []) do
    runtime = start_supervised!({DeliveryRuntime, Keyword.merge(c.opts, overrides)})
    initial = ready(runtime)
    assert {:ok, _} = DeliveryRuntime.command(runtime, initial.gate.version, "boot", "bootstrap", G.validation())
    ready(runtime)
    runtime
  end

  defp reserve(runtime) do
    assert {:error, :reconciliation_required} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("reserve ran a worker") end)
    ready(runtime)
  end

  defp start_worker(runtime, host \\ nil, letter \\ "A") do
    parent = self()

    {:ok, pid} =
      DeliveryRuntime.dispatch(runtime, issue(letter), host, fn handle ->
        send(parent, {:started, self(), handle})
        worker_loop(parent, handle)
      end)

    assert_receive {:started, ^pid, handle}
    {pid, handle}
  end

  defp worker_loop(parent, handle) do
    receive do
      :finish ->
        :ok

      :effect ->
        send(parent, {:checked, DeliveryRuntime.check(handle, :effect)})
        worker_loop(parent, handle)

      :check ->
        send(parent, {:checked, DeliveryRuntime.check(handle)})
        worker_loop(parent, handle)

      {:tool, name, args} ->
        send(parent, {:tool_result, DeliveryRuntime.tool(handle, name, args)})
        worker_loop(parent, handle)

      :bound_tool ->
        binding = %{adapter: SymphonyElixir.GitHubProjects.Adapter, tracker_settings: %{}, delivery: handle}
        send(parent, {:bound_result, SymphonyElixir.Tracker.execute_bound_agent_tool(binding, "project_context", %{}, delivery: %{})})
        worker_loop(parent, handle)
    end
  end

  defp task_tool(pid, name, args \\ %{}) do
    send(pid, {:tool, name, args})
    assert_receive {:tool_result, result}, 2_000
    result
  end

  defp effect_runner(_settings, cycle, effect, authorize, _) do
    step = Effects.next(effect) || "finalize"

    result =
      case step do
        "push" -> %{"sha" => effect["payload"]["sha"], "digest" => String.duplicate("d", 64), "base_sha" => G.sha()}
        "pull" -> %{"sha" => effect["payload"]["sha"], "pr_number" => 7, "pr_id" => "pr-node"}
        "finalize" -> %{"sha" => effect["payload"]["sha"], "pr_number" => 7, "pr_id" => "pr-node"}
        "status" -> %{"status" => "Agent working"}
        "link" -> %{"pr_id" => "pr-node", "linked" => true}
        "comment" -> %{"comment_id" => "comment"}
      end

    assert_stopped(step, cycle)
    with :ok <- if(step == "finalize", do: :ok, else: authorize.(step, result)), do: {:ok, step, result}
  end

  defp assert_stopped("push", cycle), do: assert(cycle["budget"]["interval"] == nil)
  defp assert_stopped(_, _), do: :ok

  defp publication_runtime(c, ci) do
    opts = [observer: ci_observer(c.settings, ci), publication_step: &effect_runner/5, stop_verifier: &stopped/1]
    boot(c, opts)
  end

  defp stopped(_), do: :stopped

  defp ci_observer(settings, ci_state) do
    fn _, opts ->
      context = opts[:context]
      cycle = context.state["cycle"]
      latest = if cycle, do: Budget.latest_ci(cycle["budget"])
      remote = Agent.get(ci_state, & &1)

      fact =
        if latest && cycle["work"]["pr_number"],
          do: %{
            "origin" => if(latest["run_attempt"] in [nil, remote.attempt], do: "reserved", else: "external"),
            "reservation_id" => latest["reservation_id"],
            "run_id" => 100,
            "run_attempt" => remote.attempt,
            "sha" => latest["sha"],
            "result" => remote.result,
            "failure_kind" => remote.kind
          }

      facts = Map.put(facts(), "ci", fact)
      reasons = if fact && fact["result"] != "success", do: ["pr_ci_" <> fact["result"]], else: ["manual_dev_validation_required"]
      {:ok, Observation.new(settings, context, facts, reasons)}
    end
  end

  test "task tools hand off through a stopped worker and retained CI reservation", c do
    ci = start_supervised!({Agent, fn -> %{result: "success", attempt: 1, kind: "unknown"} end}, id: :remote_ci)

    runtime =
      boot(c,
        observer: ci_observer(c.settings, ci),
        publication_step: &effect_runner/5,
        stop_verifier: &stopped/1,
        watch_transition: fn _, _, _, row, _ ->
          row = row |> Map.put("state", "Agent working") |> Map.put("large_field", String.duplicate("x", 8_000))
          {:ok, %{"watch_digest" => String.duplicate("b", 64), "row" => row}}
        end
      )

    reserve(runtime)
    {pid, handle} = start_worker(runtime)
    assert {:error, :worker_permit_revoked} = DeliveryRuntime.tool(handle, "project_start", %{})
    assert {:ok, %{"phase" => "working"}} = task_tool(pid, "project_context")
    send(pid, :bound_tool)
    assert_receive {:bound_result, %{"success" => true}}, 2_000
    assert {:error, :invalid_task_tool_arguments} = task_tool(pid, "merge")
    assert {:ok, _} = task_tool(pid, "project_start")
    await(runtime, fn s -> :sys.get_state(runtime).effect == nil and Enum.any?(s.gate.state["cycle"]["effects"], fn {_, e} -> e["steps"]["status"] != nil end) end)
    assert :sys.get_state(runtime).worker.watch_digest == String.duplicate("b", 64)
    assert {:ok, _} = task_tool(pid, "project_report", %{"body" => "Progress"})
    await(runtime, fn s -> Enum.any?(s.gate.state["cycle"]["effects"], fn {_, e} -> get_in(e, ["steps", "comment", "status"]) == "confirmed" end) end)
    assert {:ok, %{"operation_id" => op}} = task_tool(pid, "project_prepare_pr", %{"title" => "Feature", "body" => "Tested", "sha" => G.sha("b")})
    assert {:ok, %{"status" => "submitted"}} = task_tool(pid, "project_handoff", %{"operation_id" => op})
    done = await(runtime, &(&1.gate.state["cycle"]["phase"] == "awaiting_review"), 500)
    assert done.worker == nil
    assert done.gate.state["cycle"]["work"]["pr_number"] == 7
    assert map_size(done.gate.state["cycle"]["budget"]["ci"]) == 1
    refute Process.alive?(pid)
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue("B"), nil, fn _ -> :ok end)
  end

  test "owner rerun is observed on the same commit without Actions write", c do
    ci = start_supervised!({Agent, fn -> %{result: "failure", attempt: 1, kind: "unknown"} end}, id: :remote_ci)
    runtime = publication_runtime(c, ci)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    {:ok, %{"operation_id" => op}} = task_tool(pid, "project_prepare_pr", %{"title" => "Feature", "body" => "Tested", "sha" => G.sha("b")})
    assert {:ok, _} = task_tool(pid, "project_handoff", %{"operation_id" => op})
    await(runtime, &(&1.reason == :awaiting_ci_or_manual_rerun), 500)
    Agent.update(ci, &%{&1 | result: "success", attempt: 2})
    DeliveryRuntime.refresh(runtime)
    done = await(runtime, &(&1.gate.state["cycle"]["phase"] == "awaiting_review"), 500)
    assert map_size(done.gate.state["cycle"]["budget"]["ci"]) == 2
    assert done.gate.state["cycle"]["budget"]["fixes"] == 0
  end

  test "confirmed verification failure releases only the same task into fix budget", c do
    ci = start_supervised!({Agent, fn -> %{result: "failure", attempt: 1, kind: "verification"} end}, id: :remote_ci)
    runtime = publication_runtime(c, ci)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    {:ok, %{"operation_id" => op}} = task_tool(pid, "project_prepare_pr", %{"title" => "Feature", "body" => "Tested", "sha" => G.sha("b")})
    task_tool(pid, "project_handoff", %{"operation_id" => op})
    fixed = await(runtime, &(&1.gate.state["cycle"]["phase"] == "reserved" and &1.gate.state["cycle"]["budget"]["fixes"] == 1), 500)
    assert fixed.gate.state["cycle"]["work"]["pr_number"] == 7
    ready(runtime)
    {worker, _} = start_worker(runtime)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"]["budget"]["interval"]["budget"] == "fix_ms"
    {:ok, %{"operation_id" => repeated}} = task_tool(worker, "project_prepare_pr", %{"title" => "Retry", "body" => "Unchanged", "sha" => G.sha("b")})
    task_tool(worker, "project_handoff", %{"operation_id" => repeated})
    await(runtime, &(&1.reason == :publication_budget_required))
    DeliveryRuntime.pause(runtime, "operator_pause")
    DeliveryRuntime.refresh(runtime)
    await(runtime, &(&1.observation != nil))
    send(runtime, :pump_effect)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"]["phase"] == "needs_human_decision"
  end

  test "cancellation during a remote write records its result but never advances publication", c do
    parent = self()

    runner = fn _, _, effect, authorize, _ ->
      :ok = authorize.("comment", %{})
      send(parent, {:remote_sent, self(), effect["operation_id"]})

      receive do
        :complete -> {:ok, "comment", %{"comment_id" => "comment"}}
      end
    end

    runtime = boot(c, publication_step: runner, stop_verifier: &stopped/1)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    task_tool(pid, "project_report", %{"body" => "Progress"})
    assert_receive {:remote_sent, writer, op}, 2_000
    version = DeliveryRuntime.status(runtime).gate.version
    assert {:ok, _} = DeliveryRuntime.command(runtime, version, "cancel-write", "request_cancel", G.operator())
    send(writer, :complete)
    cancelled = await(runtime, &(get_in(&1.gate.state, ["cycle", "effects", op, "steps", "comment", "status"]) == "confirmed"))
    assert cancelled.gate.state["cycle"]["phase"] == "cancelling"
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue("B"), nil, fn _ -> :ok end)
  end

  test "a blocking report stops the task and retains ownership", c do
    runtime = boot(c, publication_step: &effect_runner/5, stop_verifier: &stopped/1)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    assert {:ok, _} = task_tool(pid, "project_block", %{"body" => "Need a decision"})
    state = await(runtime, &(&1.gate.state["cycle"]["block_reason"] == "agent_requested_human_decision"))
    assert state.worker == nil
    assert state.gate.state["cycle"]["phase"] == "needs_human_decision"
  end

  test "publisher death and rate limits retain intent and enforce read backoff", c do
    behavior = start_supervised!({Agent, fn -> :die end}, id: :publisher_behavior)

    runner = fn _, _, _, _, _ ->
      case Agent.get(behavior, & &1) do
        :die -> exit(:shutdown)
        :limited -> {:error, {:publication_limited, 90}}
        :error -> {:error, :disconnected}
      end
    end

    runtime = boot(c, publication_step: runner, freshness_ms: 1_000_000)
    reserve(runtime)
    {pid, handle} = start_worker(runtime)
    task_tool(pid, "project_report", %{"body" => "Progress"})
    await(runtime, &(&1.reason == :publication_result_unknown))
    assert :sys.get_state(runtime).effect_retry_at == 30_000
    Agent.update(behavior, fn _ -> :limited end)
    Agent.update(c.clock, fn _ -> 30_000 end)
    send(runtime, :pump_effect)
    await(runtime, fn _ -> :sys.get_state(runtime).effect_retry_at == 120_000 end)
    Agent.update(behavior, fn _ -> :error end)
    Agent.update(c.clock, fn _ -> 120_000 end)
    send(runtime, :pump_effect)
    await(runtime, fn _ -> :sys.get_state(runtime).effect_retry_at == 150_000 end)
    assert {:error, :worker_permit_revoked} = GenServer.call(runtime, {:tool, handle, "project_report", %{}})
    assert {:error, :effect_revoked} = GenServer.call(runtime, {:effect_send, "spoof", "comment", %{}})
    send(pid, :finish)
  end

  test "late publication authorization after cancellation is rejected", c do
    parent = self()

    runner = fn _, _, _, authorize, _ ->
      send(parent, {:ready_to_send, self()})

      receive do
        :continue -> send(parent, {:late_authorization, authorize.("comment", %{})})
      end

      {:error, :revoked}
    end

    runtime = boot(c, publication_step: runner, stop_verifier: &stopped/1)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    task_tool(pid, "project_report", %{"body" => "Progress"})
    assert_receive {:ready_to_send, publisher}, 2_000
    send(runtime, :pump_effect)
    version = DeliveryRuntime.status(runtime).gate.version
    DeliveryRuntime.command(runtime, version, "cancel-before-send", "request_cancel", G.operator())
    send(publisher, :continue)
    assert_receive {:late_authorization, {:error, :effect_revoked}}, 2_000
    state = await(runtime, &(&1.reason == :publication_result_unknown))
    assert Enum.all?(state.gate.state["cycle"]["effects"], fn {_, effect} -> effect["steps"] == %{} end)
  end

  test "a foreign operation response cannot settle the real outbox", c do
    parent = self()

    runner = fn _, _, _, authorize, _ ->
      send(parent, {:bad_authorization, authorize.("unknown", %{})})
      {:ok, "unknown", %{}}
    end

    runtime = boot(c, publication_step: runner)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    task_tool(pid, "project_report", %{"body" => "Progress"})
    assert_receive {:bad_authorization, {:error, :effect_send_not_allowed}}, 2_000
    await(runtime, &(&1.reason == :publication_reconciliation_required))
    send(pid, :finish)
  end

  test "an already observed report can complete without another mutation", c do
    runtime = boot(c, publication_step: fn _, _, _, _, _ -> {:ok, "comment", %{"comment_id" => "existing"}} end)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    {:ok, %{"operation_id" => id}} = task_tool(pid, "project_report", %{"body" => "Progress"})
    await(runtime, &(get_in(&1.gate.state, ["cycle", "effects", id, "steps", "comment", "status"]) == "confirmed"))
    send(pid, :finish)
  end

  test "a running watch is cancelled before the controller changes Status", c do
    parent = self()

    watch = fn _, _, _, _ ->
      send(parent, {:watch_blocked, self()})

      receive do
        :never -> :ok
      end
    end

    transition = fn _, _, _, _, _ -> {:ok, %{}} end
    writer = &effect_runner/5
    runtime = boot(c, watch: watch, publication_step: writer, stop_verifier: &stopped/1, watch_transition: transition)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    DeliveryRuntime.refresh(runtime)
    assert_receive {:watch_blocked, watcher}, 2_000
    task_tool(pid, "project_start")
    await(runtime, &(&1.worker == nil))
    refute Process.alive?(watcher)
    refute Process.alive?(pid)
  end

  test "changed deployment attempt blocks publication on the same dev commit", c do
    proof = start_supervised!({Agent, fn -> 1 end}, id: :deployment_attempt)

    observer = fn _, opts ->
      deployment = G.deployment("a", Agent.get(proof, & &1))
      {:ok, Observation.new(c.settings, opts[:context], Map.put(facts(), "deployment", deployment), [])}
    end

    runtime = boot(c, observer: observer, publication_step: &effect_runner/5, stop_verifier: &stopped/1)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    {:ok, %{"operation_id" => op}} = task_tool(pid, "project_prepare_pr", %{"title" => "Feature", "body" => "Ready", "sha" => G.sha("b")})
    Agent.update(proof, fn _ -> 2 end)
    task_tool(pid, "project_handoff", %{"operation_id" => op})
    state = await(runtime, &(&1.reason == :publication_observation_required))
    assert state.gate.state["cycle"]["budget"]["ci"] == %{}
    refute Effects.sent?(state.gate.state["cycle"])
  end

  test "cancellation while final readback runs cannot become handoff", c do
    parent = self()

    runner = fn settings, cycle, effect, authorize, opts ->
      if Effects.next(effect) == nil do
        send(parent, {:final_readback, self()})

        receive do
          :continue -> effect_runner(settings, cycle, effect, authorize, opts)
        end
      else
        effect_runner(settings, cycle, effect, authorize, opts)
      end
    end

    ci = start_supervised!({Agent, fn -> %{result: "success", attempt: 1, kind: "unknown"} end}, id: :remote_ci)
    opts = [observer: ci_observer(c.settings, ci), publication_step: runner, stop_verifier: &stopped/1]
    runtime = boot(c, opts)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    {:ok, %{"operation_id" => op}} = task_tool(pid, "project_prepare_pr", %{"title" => "Feature", "body" => "Ready", "sha" => G.sha("b")})
    task_tool(pid, "project_handoff", %{"operation_id" => op})
    assert_receive {:final_readback, writer}, 3_000
    version = DeliveryRuntime.status(runtime).gate.version
    DeliveryRuntime.command(runtime, version, "cancel-final", "request_cancel", G.operator())
    send(writer, :continue)
    state = await(runtime, &(&1.observation != nil))
    assert state.gate.state["cycle"]["phase"] == "cancelling"
  end

  test "tool returns a bounded error when the controller disconnects after permit check" do
    runtime =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:check, _, _}} -> GenServer.reply(from, :ok)
        end

        receive do
          {:"$gen_call", _, {:tool, _, _, _}} -> :ok
        end
      end)

    gate =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:worker_check, _, _}} -> GenServer.reply(from, :ok)
        end
      end)

    assert {:error, :delivery_runtime_unavailable} = DeliveryRuntime.tool(%{runtime: runtime, gate: gate, nonce: make_ref()}, "project_context", %{})
  end

  test "recovery publisher can reserve against its approved broken-dev base", c do
    runtime = boot(c, publication_step: fn _, _, _, _, _ -> {:error, :no_transport} end, stop_verifier: &stopped/1)
    reserve(runtime)
    DeliveryRuntime.pause(runtime, "needs_recovery")
    DeliveryRuntime.refresh(runtime)
    ready(runtime)
    recovery = Map.merge(G.recovery(), %{"item_id" => "item-B", "issue_id" => "issue-B", "sha" => G.sha()})
    version = DeliveryRuntime.status(runtime).gate.version
    assert {:ok, _} = DeliveryRuntime.command(runtime, version, "recovery", "assign_recovery", recovery)
    ready(runtime)
    {pid, _} = start_worker(runtime, nil, "B")
    {:ok, %{"operation_id" => op}} = task_tool(pid, "project_prepare_pr", %{"title" => "Recovery", "body" => "Fix", "sha" => G.sha("b")})
    task_tool(pid, "project_handoff", %{"operation_id" => op})
    state = await(runtime, &(&1.reason == :publication_result_unknown))
    assert state.gate.state["cycle"]["recovery"] != nil
    assert map_size(state.gate.state["cycle"]["budget"]["ci"]) == 1
  end

  test "one owner retains work and budget through normal continuation", c do
    parent = self()
    hold_observation = start_supervised!({Agent, fn -> false end}, id: :hold_observation)

    observer = fn settings, opts ->
      if Agent.get(hold_observation, & &1) do
        send(parent, {:continuation_observation, self()})

        receive do
          :continue -> :ok
        end
      end

      c.opts[:observer].(settings, opts)
    end

    runtime = boot(c, observer: observer)
    reserve(runtime)
    {pid, handle} = start_worker(runtime)
    assert handle.context["mode"] == "new"
    assert handle.context["expected_dev_sha"] == G.sha()
    assert {:error, :worker_not_stopped} = DeliveryRuntime.dispatch(runtime, issue("B"), nil, fn _ -> :ok end)
    send(pid, :check)
    assert_receive {:checked, :ok}
    Agent.update(c.clock, fn _ -> 9_000 end)
    send(runtime, :tick)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"]["budget"]["initial_ms"] == 9_000
    send(pid, :finish)
    state = await(runtime, &(&1.worker == nil and &1.observation != nil))
    assert state.gate.state["cycle"]["budget"]["interval"] == nil
    assert {:error, :cycle_occupied} = DeliveryRuntime.dispatch(runtime, issue("B"), nil, fn _ -> :ok end)
    {next, continued} = start_worker(runtime)
    assert continued.context["mode"] == "continue"
    Agent.update(hold_observation, fn _ -> true end)
    send(next, :finish)
    assert_receive {:continuation_observation, reader}, 2_000
    assert DeliveryRuntime.status(runtime).worker == nil
    assert {:error, :observation_required} = DeliveryRuntime.cleanup(runtime, "/work/GHP-6974656d2d41")
    send(reader, :continue)
    ready(runtime)
    assert {:error, :workspace_cycle_retained} = DeliveryRuntime.cleanup(runtime, "/work/GHP-6974656d2d41")
  end

  test "cancellation stops the worker and preserves occupied state and measured time", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, handle} = start_worker(runtime)
    Agent.update(c.clock, fn _ -> 15_000 end)
    version = DeliveryRuntime.status(runtime).gate.version
    assert {:ok, _} = DeliveryRuntime.command(runtime, version, "cancel", "request_cancel", G.operator())
    state = await(runtime, &(&1.worker == nil and &1.observation != nil))
    assert state.gate.state["cycle"]["phase"] == "cancelling"
    assert state.gate.state["cycle"]["budget"]["initial_ms"] == 15_000
    refute Process.alive?(pid)
    assert {:error, :worker_permit_revoked} = DeliveryRuntime.check(handle)
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("cancelled worker resumed") end)
  end

  test "unconfirmed external stop retains interval and blocks the next worker", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, _} = start_worker(runtime, "worker")
    send(pid, :effect)
    assert_receive {:checked, :ok}
    assert :ok = DeliveryRuntime.pause(runtime, "operator_pause")
    state = await(runtime, &(&1.worker.status == :stop_unconfirmed))
    assert state.gate.state["cycle"]["budget"]["interval"] != nil
    assert state.reason == :stop_unconfirmed
    assert {:error, :worker_not_stopped} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> :ok end)
  end

  test "time exhaustion stops work without borrowing the fix budget", c do
    runtime = boot(c, freshness_ms: 3_700_000)
    reserve(runtime)
    start_worker(runtime)
    Agent.update(c.clock, fn _ -> 3_600_001 end)
    send(runtime, :tick)
    state = await(runtime, &(&1.worker == nil and &1.observation != nil))
    assert state.gate.state["cycle"]["budget"]["initial_ms"] == 3_600_001
    assert state.gate.state["cycle"]["budget"]["fix_ms"] == 0
    assert state.gate.state["cycle"]["phase"] == "needs_human_decision"
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> :ok end)
  end

  test "reload stops work and requires restart without resetting ownership", c do
    runtime = boot(c)
    reserve(runtime)
    start_worker(runtime)
    assert :ok = DeliveryRuntime.check_settings(runtime, c.config)
    changed = put_in(c.config.tracker.provider["item_ids"], ["item-B"]).config
    assert {:error, :restart_required} = DeliveryRuntime.check_settings(runtime, changed)
    state = await(runtime, &(&1.worker == nil))
    assert state.restart_required
    send(runtime, :pump_effect)
    assert state.gate.state["cycle"]["task"]["item_id"] == "item-A"
    assert {:error, :restart_required} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> :ok end)
  end

  test "unavailable observation cannot admit, bootstrap or clean", c do
    runtime = start_supervised!({DeliveryRuntime, Keyword.put(c.opts, :observer, fn _, _ -> {:error, :unavailable} end)})
    await(runtime, &(&1.reason == :observation_unavailable))
    assert {:error, :observation_required} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> :ok end)
    assert {:error, :observation_required} = DeliveryRuntime.cleanup(runtime, "/work/a")
    assert {:error, :reconciliation_required} = DeliveryRuntime.command(runtime, DeliveryGate.status(c.gate).version, "boot", "bootstrap", G.validation())
    refute File.exists?(c.settings.gate.path)
  end

  test "refresh coalesces, late observation is rejected and rate limit delays new reads", c do
    parent = self()

    observer = fn _, opts ->
      send(parent, {:read_started, self(), Keyword.fetch!(opts, :context)})

      receive do
        {:result, result} -> result
      end
    end

    runtime = start_supervised!({DeliveryRuntime, Keyword.put(c.opts, :observer, observer)})
    assert_receive {:read_started, reader, context}
    DeliveryRuntime.refresh(runtime)
    DeliveryRuntime.status(runtime)
    refute_receive {:read_started, _, _}, 20
    obs = Observation.failure(c.settings, context, {:github_delivery_limited, 120})
    send(reader, {:result, {:ok, obs}})
    await(runtime, &(&1.reason == :stale_or_incomplete_observation))
    Agent.update(c.clock, fn _ -> 30_000 end)
    DeliveryRuntime.refresh(runtime)
    refute_receive {:read_started, _, _}, 20
    Agent.update(c.clock, fn _ -> 120_000 end)
    DeliveryRuntime.refresh(runtime)
    assert_receive {:read_started, next, _}
    Process.exit(next, :kill)
    await(runtime, &(&1.reason == :observation_failed))
    Agent.update(c.clock, fn _ -> 150_000 end)
    DeliveryRuntime.refresh(runtime)
    assert_receive {:read_started, _, _}
    read = :sys.get_state(runtime).read
    send(runtime, {:read_timeout, read.task.ref})
    await(runtime, &(&1.reason == :observation_deadline))
    send(runtime, {:read_timeout, make_ref()})
    assert DeliveryRuntime.status(runtime).reason == :observation_deadline
  end

  test "watch refresh does not authorize a new interval and obsolete handles cannot stop its successor", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, handle} = start_worker(runtime)
    Agent.update(c.clock, fn _ -> 30_000 end)
    DeliveryRuntime.refresh(runtime)
    await(runtime, fn _ -> :sys.get_state(runtime).worker.checked_at == 30_000 end)
    send(pid, :finish)
    ready(runtime)
    {next, _} = start_worker(runtime)
    assert {:error, :worker_permit_revoked} = DeliveryRuntime.check(handle)
    assert Process.alive?(next)
    send(next, :check)
    assert_receive {:checked, :ok}
    Agent.update(c.clock, fn _ -> 91_000 end)
    send(next, :check)
    await(runtime, &(&1.worker == nil))
    assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "needs_human_decision"
  end

  test "deadline and controller shutdown revoke running processes", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    interval = DeliveryRuntime.status(runtime).worker.interval
    send(runtime, {:work_deadline, interval})
    await(runtime, &(&1.worker == nil))
    refute Process.alive?(pid)
    send(runtime, {:work_deadline, "old-interval"})
    state = ready(runtime)
    assert {:ok, _} = DeliveryRuntime.command(runtime, state.gate.version, "resume", "resume", Map.put(G.operator(), "sha", G.sha()))
    ready(runtime)
    {next, handle} = start_worker(runtime)
    assert :ok = stop_supervised(DeliveryRuntime)
    refute Process.alive?(next)
    assert {:error, :delivery_runtime_unavailable} = DeliveryRuntime.check(handle)
    assert DeliveryGate.status(c.gate).state["cycle"]["budget"]["interval"] != nil
  end

  test "failed admission or exhausted task supervisor cannot execute the supplied worker", c do
    runtime = boot(c)
    context = DeliveryGate.status(c.gate)
    :ok = DeliveryGate.reconcile(c.gate, context.version, c.settings.gate.scope, G.sha("b"))
    assert {:error, :unvalidated_base} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("invalid base") end)
    :ok = DeliveryGate.reconcile(c.gate, context.version, c.settings.gate.scope, G.sha())
    reserve(runtime)
    context = DeliveryGate.status(c.gate)
    :ok = DeliveryGate.reconcile(c.gate, context.version, c.settings.gate.scope, G.sha("b"))
    assert {:error, :unvalidated_base} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("invalid permit") end)
    ready(runtime)
    limited = start_supervised!({Task.Supervisor, max_children: 0}, id: :limited)
    :sys.replace_state(runtime, &%{&1 | tasks: limited})
    assert {:error, :spawn_failed} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("capacity exceeded") end)
  end

  test "inert worker expiry cannot execute hooks without activation", c do
    runtime = boot(c, activation_timeout_ms: 0)
    reserve(runtime)
    parent = self()

    case DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> send(parent, :uncommitted_worker) end) do
      {:ok, _pid} -> await(runtime, &(&1.worker == nil))
      {:error, :work_start_rejected} -> :ok
    end

    refute_receive :uncommitted_worker, 20
  end

  test "abrupt coordinator loss kills its worker and retains uncertain budget", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    ref = Process.monitor(pid)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    assert DeliveryGate.status(c.gate).state["cycle"]["budget"]["interval"] != nil
  end

  test "observer advances CI, review and deployment without a worker or duplicate spending", c do
    source = start_supervised!({Agent, fn -> facts() end}, id: :facts)

    observer = fn _, opts ->
      context = Keyword.fetch!(opts, :context)
      {:ok, Observation.new(c.settings, context, Agent.get(source, & &1), ["manual_dev_validation_required"])}
    end

    runtime = boot(c, observer: observer)
    reserve(runtime)
    state = ready(runtime)
    assert {:ok, _} = DeliveryRuntime.command(runtime, state.gate.version, "ci", "reserve_ci", G.ci_request())
    await(runtime, &(&1.observation != nil))
    ci = Map.put(G.ci_result("ci-1", "pending"), "origin", "reserved")
    Agent.update(source, &Map.put(&1, "ci", ci))
    DeliveryRuntime.refresh(runtime)
    await(runtime, &(get_in(&1.gate.state, ["cycle", "budget", "ci", "ci-1", "result"]) == "pending"))
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue("B"), nil, fn _ -> flunk("CI owner lost") end)
    Agent.update(source, &put_in(&1, ["ci", "result"], "success"))
    DeliveryRuntime.refresh(runtime)
    state = ready(runtime)
    # Wait for the successful observation as reconciliation cannot succeed on pending CI.
    assert map_size(state.gate.state["cycle"]["budget"]["ci"]) == 1
    assert state.gate.state["cycle"]["budget"]["initial_ms"] == 0
    assert {:ok, _} = DeliveryRuntime.command(runtime, state.gate.version, "review", "handoff", %{"pr_number" => 7, "sha" => G.sha("b")})
    state = ready(runtime)
    DeliveryRuntime.refresh(runtime)
    assert ready(runtime).gate.version == state.gate.version
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("review restarted") end)
    Agent.update(source, &Map.merge(&1, %{"pr" => %{"state" => "merged", "ancestry" => "included", "number" => 7, "merge_sha" => G.sha("c")}, "dev_sha" => G.sha("c"), "deployment" => G.deployment()}))
    DeliveryRuntime.refresh(runtime)
    state = await(runtime, &(&1.gate.state["cycle"]["phase"] == "awaiting_validation" and &1.observation != nil))
    assert state.worker == nil
    assert state.observation.manual_validation == "pending"
    assert map_size(state.gate.state["cycle"]["budget"]["ci"]) == 1
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue("B"), nil, fn _ -> flunk("validation bypassed") end)
    # A changed final result cannot overwrite a previously committed CI result.
    Agent.update(source, &put_in(&1, ["ci", "result"], "failure"))
    DeliveryRuntime.refresh(runtime)
    await(runtime, &(&1.reason == :transition_rejected))
    assert DeliveryGate.status(c.gate).state["cycle"]["budget"]["ci"]["ci-1"]["result"] == "success"
  end

  test "late watch after cancellation cannot refresh permission or resurrect the worker", c do
    parent = self()

    watch = fn _, _, _, _ ->
      send(parent, {:watching, self()})

      receive do
        :reply -> :ok
      end
    end

    runtime = boot(c, watch: watch)
    reserve(runtime)
    start_worker(runtime)
    Agent.update(c.clock, fn _ -> 30_000 end)
    DeliveryRuntime.refresh(runtime)
    assert_receive {:watching, reader}
    version = DeliveryRuntime.status(runtime).gate.version
    assert {:ok, _} = DeliveryRuntime.command(runtime, version, "cancel", "request_cancel", G.operator())
    await(runtime, &(&1.worker == nil))
    send(reader, :reply)
    await(runtime, fn _ -> :sys.get_state(runtime).read == nil end)
    send(runtime, :tick)
    ready(runtime)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"]["phase"] == "cancelling"
    assert {:error, _} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("stale watch allowed work") end)
  end

  test "poll cadence and failed reads survive worker stop without a request storm", c do
    parent = self()

    watch = fn _, _, _, _ ->
      send(parent, :watch_called)
      {:error, {:github_delivery_limited, 120}}
    end

    runtime = boot(c, watch: watch, poll_ms: 30_000)
    reserve(runtime)
    start_worker(runtime)
    DeliveryRuntime.refresh(runtime)
    refute_receive :watch_called, 20
    Agent.update(c.clock, fn _ -> 30_000 end)
    DeliveryRuntime.refresh(runtime)
    assert_receive :watch_called
    await(runtime, &(&1.worker == nil))
    DeliveryRuntime.refresh(runtime)
    assert DeliveryRuntime.status(runtime).observation == nil
    assert :sys.get_state(runtime).read == nil
    Agent.update(c.clock, fn _ -> 60_000 end)
    DeliveryRuntime.refresh(runtime)
    assert DeliveryRuntime.status(runtime).observation == nil
    Agent.update(c.clock, fn _ -> 150_000 end)
    DeliveryRuntime.refresh(runtime)
    ready(runtime)
  end

  test "freshness expiry stops a silent worker even without its next turn", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    Agent.update(c.clock, fn _ -> 60_001 end)
    send(runtime, :tick)
    await(runtime, &(&1.worker == nil))
    refute Process.alive?(pid)
    assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "needs_human_decision"
  end

  test "a checkpoint cannot keep a worker running after its gate was blocked", c do
    runtime = boot(c)
    reserve(runtime)
    {pid, _} = start_worker(runtime)
    version = DeliveryGate.status(c.gate).version
    assert {:ok, _} = DeliveryGate.execute(c.gate, version, "external-block", "block", %{"reason" => "operator_pause"})
    send(runtime, :tick)
    await(runtime, &(&1.worker == nil))
    refute Process.alive?(pid)
    assert DeliveryGate.status(c.gate).state["cycle"]["budget"]["interval"] == nil
    assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "needs_human_decision"
  end
end
