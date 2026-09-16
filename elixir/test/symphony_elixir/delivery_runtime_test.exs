defmodule SymphonyElixir.DeliveryRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
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

  defp start_worker(runtime, host \\ nil) do
    parent = self()

    {:ok, pid} =
      DeliveryRuntime.dispatch(runtime, issue(), host, fn handle ->
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
    end
  end

  test "one owner retains work and budget through normal continuation", c do
    runtime = boot(c)
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
    send(next, :finish)
    await(runtime, &(&1.worker == nil))
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
