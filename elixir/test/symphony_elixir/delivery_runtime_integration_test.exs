defmodule SymphonyElixir.DeliveryRuntimeIntegrationTest do
  use SymphonyElixir.TestSupport
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{AgentRuntimeSupervisor, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.DeliveryRuntime.Guard
  alias SymphonyElixir.GitHubProjects.Delivery.Observation
  alias SymphonyElixir.Runtime.Worker

  test "isolated task explicitly pins model and effort for each turn and records the acknowledged pair", c do
    {runtime, trace} = isolated_model_runtime(c)
    reserve()
    parent = self()

    assert {:ok, _} =
             DeliveryRuntime.dispatch(runtime, issue(), nil, fn handle ->
               with {:ok, host} <- Worker.prepare(handle),
                    {:ok, session} <- AppServer.start_session("/workspace/repo", worker_host: host, delivery: handle) do
                 try do
                   first = AppServer.run_turn(session, "first", issue())
                   second = AppServer.run_turn(session, "continue", issue())
                   send(parent, {:turns, first, second})
                   receive do: (:finish -> :ok)
                 after
                   AppServer.stop_session(session)
                 end
               else
                 error -> send(parent, {:failed, error})
               end
             end)

    assert_receive {:turns, {:ok, _}, {:ok, _}}, 5_000
    assert Worker.status().model["applied"] == %{"model" => "fixture-model", "effort" => "high"}
    calls = trace |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert Enum.count(calls, &(&1["method"] == "model/list")) == 2
    thread = Enum.find(calls, &(&1["method"] == "thread/start"))["params"]
    assert thread["model"] == "fixture-model"
    assert thread["config"]["model_reasoning_effort"] == "high"

    for turn <- Enum.filter(calls, &(&1["method"] == "turn/start")) do
      assert turn["params"]["model"] == "fixture-model"
      assert turn["params"]["effort"] == "high"
    end

    assert :ok = DeliveryRuntime.shutdown(runtime)
    await(fn -> DeliveryRuntime.status(runtime).worker == nil end)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"] != nil
    send(runtime, :tick)
    await(fn -> :sys.get_state(Worker).closing end)
    send(Worker, :poll)
  end

  test "different acknowledged effort blocks the task before any turn is sent", c do
    {runtime, trace} = isolated_model_runtime(c, "medium")
    reserve()
    parent = self()

    assert {:ok, _} =
             DeliveryRuntime.dispatch(runtime, issue(), nil, fn handle ->
               {:ok, host} = Worker.prepare(handle)
               send(parent, {:session, AppServer.start_session("/workspace/repo", worker_host: host, delivery: handle)})
               receive do: (:finish -> :ok)
             end)

    assert_receive {:session, {:error, :model_application_mismatch}}, 5_000
    refute File.read!(trace) =~ "turn/start"
    refute Worker.status().ready
    assert Worker.status().reasons == [:model_application_mismatch]
    assert :ok = DeliveryRuntime.shutdown(runtime)
  end

  test "model rerouting stops the turn and blocks further admission", c do
    {runtime, trace} = isolated_model_runtime(c)
    reserve()
    parent = self()

    assert {:ok, _} =
             DeliveryRuntime.dispatch(runtime, issue(), nil, fn handle ->
               {:ok, host} = Worker.prepare(handle)
               {:ok, session} = AppServer.start_session("/workspace/repo", worker_host: host, delivery: handle)

               try do
                 send(parent, {:rerouted, AppServer.run_turn(session, "reroute", issue())})
                 receive do: (:finish -> :ok)
               after
                 AppServer.stop_session(session)
               end
             end)

    assert_receive {:rerouted, {:error, :codex_model_rerouted}}, 5_000
    refute Worker.status().ready
    assert Worker.status().reasons == [:codex_model_rerouted]
    assert Worker.status().model["applied"] == nil
    calls = trace |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert Enum.count(calls, &(&1["method"] == "turn/start")) == 1
    assert :ok = DeliveryRuntime.shutdown(runtime)
  end

  for failure <- ["login", "endpoint", "credential"] do
    @startup_failure failure
    test "isolated startup refuses #{@startup_failure} failure without sending a prompt", c do
      {runtime, trace} = isolated_model_runtime(c, @startup_failure)
      reserve()
      parent = self()

      assert {:ok, _} =
               DeliveryRuntime.dispatch(runtime, issue(), nil, fn handle ->
                 send(parent, {:startup, Worker.prepare(handle)})
                 receive do: (:finish -> :ok)
               end)

      assert_receive {:startup, {:error, :isolated_worker_start_unconfirmed}}, 5_000
      refute File.exists?(trace)
      send(runtime, :runtime_worker_lost)
      await(fn -> DeliveryRuntime.status(runtime).worker == nil end)
      assert DeliveryRuntime.status(runtime).gate.state["cycle"] != nil
      send(runtime, :runtime_activation_invalid)
    end
  end

  test "runtime stop crash is not treated as confirmed resource removal", c do
    {runtime, _} = start_runtime(c, stop_verifier: fn _ -> exit(:offline) end)
    reserve()
    parent = self()

    assert {:ok, _} =
             DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ ->
               send(parent, :running)
               receive do: (:finish -> :ok)
             end)

    assert_receive :running
    assert :ok = DeliveryRuntime.pause(runtime, "stop")
    await(fn -> DeliveryRuntime.status(runtime).reason == :stop_unconfirmed end)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"] != nil
  end

  test "launcher stop request requires the current private token", c do
    {runtime, _} = isolated_model_runtime(c)
    send(runtime, :tick)
    refute :sys.get_state(runtime).closing
    request = Path.join(c.root, "shutdown.request")
    File.write!(request, Jason.encode!(%{"token" => "stale"}))
    send(Worker, :poll)
    refute :sys.get_state(Worker).closing
    File.write!(request, Jason.encode!(%{"token" => "fixture"}))
    send(Worker, :poll)
    await(fn -> :sys.get_state(Worker).closing end)
    send(runtime, :tick)
    await(fn -> :sys.get_state(Worker).finishing end)
    send(Worker, :poll)
    assert DeliveryRuntime.status(runtime).worker == nil
  end

  defp isolated_model_runtime(c, actual_effort \\ "high") do
    config = put_in(c.config.tracker.provider["item_ids"], ["item-A"]).config
    {:ok, settings} = Config.delivery_observer_settings(config)
    c = %{c | config: config, settings: settings}
    {runtime, _} = start_runtime(c, isolated: true, stop_verifier: &Worker.stop/1)
    {:ok, record} = Agent.start_link(fn -> %{} end)
    selection = %{"model" => "fixture-model", "effort" => "high"}

    transport = fn _, _, request, _ ->
      case request["action"] do
        "prepare" ->
          ctx = request["context"]
          value = %{"cycle" => ctx["cycle_id"], "interval" => ctx["interval_id"], "generation" => ctx["interval_id"]}
          store_model_record(record, value)
          {:ok, %{}}

        "start" ->
          {:ok,
           Map.merge(Agent.get(record, & &1), %{"host" => "symphony-task-" <> request["generation"], "ssh_config" => "/private/fixture", "workspace" => "/workspace/repo", "selection" => selection})}

        "model_applied" ->
          {:ok, %{"applied" => request["selection"]}}

        "stop" ->
          {:ok, %{"phase" => "stopped"}}

        _ ->
          {:ok, %{"ready" => true, "reasons" => []}}
      end
    end

    activation = %{
      helper: "fixture",
      config: "fixture",
      proof: %{"state_root" => c.root, "launch_token" => "fixture"},
      transport: transport,
      credential: fn -> {:ok, "fixture"} end,
      probe: fn _, _, _ -> model_probe(actual_effort, record) end
    }

    activation = if actual_effort == "credential", do: Map.delete(activation, :credential), else: activation

    worker_config =
      if actual_effort == "credential" do
        provider = %{"repo" => "ExampleOrg/app", "github_app" => %{"app_id" => "1", "installation_id" => "2", "private_key_path" => "/nonexistent/fixture.pem"}}
        put_in(config.tracker.provider, provider)
      else
        config
      end

    tasks = start_supervised!({Task.Supervisor, name: __MODULE__.WorkerTasks})
    start_supervised!({Worker, activation: activation, config: worker_config, tasks: tasks, runtime: runtime})
    await(fn -> Worker.status().ready end)
    trace = Path.join(c.root, "model-trace.jsonl")
    fake = Path.join(c.root, "ssh")

    File.write!(fake, """
    #!/usr/bin/python3
    import json,sys
    for line in sys.stdin:
        value=json.loads(line)
        with open(#{inspect(trace)},'a') as output: output.write(json.dumps(value)+'\\n')
        method=value.get('method')
        if 'id' not in value: continue
        if method=='initialize': result={}
        elif method=='model/list':
            if value['params']['cursor'] is None: result={'data':[], 'nextCursor':'second'}
            else: result={'data':[{'model':'fixture-model','supportedReasoningEfforts':[{'reasoningEffort':'high'}]}],'nextCursor':None}
        elif method=='thread/start': result={'thread':{'id':'thread'},'model':'fixture-model','reasoningEffort':#{inspect(actual_effort)}}
        elif method=='turn/start': result={'turn':{'id':'turn'}}
        else: result={}
        print(json.dumps({'id':value['id'],'result':result}),flush=True)
        if method=='turn/start':
            event='model/rerouted' if 'reroute' in json.dumps(value['params']['input']) else 'turn/completed'
            print(json.dumps({'method':event,'params':{}}),flush=True)
    """)

    File.chmod!(fake, 0o700)
    old_path = System.get_env("PATH")
    System.put_env("PATH", c.root <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
    {runtime, trace}
  end

  defp store_model_record(record, value), do: Agent.update(record, fn _ -> value end)

  defp model_probe("login", _), do: {:error, :codex_login_required}
  defp model_probe("endpoint", _), do: {:error, :worker_probe_failed}

  defp model_probe(_, record) do
    attempts = Agent.get_and_update(record, fn value -> {Map.get(value, "probes", 0), Map.update(value, "probes", 1, &(&1 + 1))} end)
    if attempts == 0, do: {:error, :worker_probe_failed}, else: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    saved = :sys.get_state(WorkflowStore)
    on_exit(fn -> :sys.replace_state(WorkflowStore, fn _ -> saved end) end)
    root = Path.dirname(Workflow.workflow_file_path())
    config = put_in(F.fixture().config.delivery.state_path, Path.join(root, "cycle.json")).config
    File.chmod!(root, 0o700)
    {:ok, settings} = Config.delivery_observer_settings(config)
    %{config: config, settings: settings, root: root}
  end

  defp await(fun, attempts \\ 200)
  defp await(_, 0), do: flunk("expected lifecycle state was not reached")

  defp await(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        await(fun, attempts - 1)

      false ->
        Process.sleep(10)
        await(fun, attempts - 1)

      result ->
        result
    end
  end

  defp facts do
    row = %{
      "item_id" => "item-A",
      "state" => "Ready for agent",
      "eligible" => true,
      "archived" => false,
      "issue_state" => "OPEN",
      "native_ref" => %{"issue_id" => "issue-A", "repo" => "ExampleOrg/app"}
    }

    %{"project" => %{"items" => [row]}, "dev_sha" => G.sha(), "deployment" => G.deployment("a"), "watch_digest" => "digest"}
  end

  defp issue do
    %Issue{id: "item-A", identifier: "GHP-6974656d2d41", title: "Runtime integration", state: "Ready for agent", dispatchable: true, native_ref: hd(facts()["project"]["items"])["native_ref"]}
  end

  defp options(c) do
    [observer: fn _, opts -> {:ok, Observation.new(c.settings, opts[:context], facts(), ["manual_dev_validation_required"])} end, watch: fn _, _, _, _ -> :ok end, checkpoint_ms: 100_000, poll_ms: 0]
  end

  defp ready do
    await(fn ->
      state = DeliveryRuntime.status()
      if state.observation != nil and state.gate.mode == :reconciled, do: state
    end)
  end

  defp start_runtime(c, extra \\ []) do
    gate = start_supervised!({DeliveryGate, settings: c.settings.gate})
    tasks = start_supervised!(Task.Supervisor)
    opts = [name: DeliveryRuntime, config: c.config, gate: gate, task_supervisor: tasks] ++ Keyword.merge(options(c), extra)
    runtime = start_supervised!({DeliveryRuntime, opts})
    {runtime, gate}
  end

  test "slow resource stop does not block status, pause or shutdown", c do
    parent = self()

    verifier = fn _ ->
      send(parent, {:confirm_stop, self()})

      receive do
        :confirm -> :stopped
      end
    end

    {runtime, _} = start_runtime(c, stop_verifier: verifier)
    reserve()

    {:ok, worker} =
      DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ ->
        send(parent, :working)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :working
    assert :ok = DeliveryRuntime.shutdown(runtime)
    assert_receive {:confirm_stop, verifier_pid}
    refute Process.alive?(worker)
    assert DeliveryRuntime.status(runtime).worker != nil
    assert :ok = DeliveryRuntime.pause(runtime, "operator requested")
    assert {:error, :controller_shutdown} = DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ -> flunk("late dispatch") end)
    send(verifier_pid, :confirm)
    await(fn -> DeliveryRuntime.status(runtime).worker == nil end)
    assert DeliveryRuntime.status(runtime).gate.state["cycle"] != nil
  end

  defp reserve do
    state = ready()
    assert {:ok, _} = DeliveryRuntime.command(DeliveryRuntime, state.gate.version, "bootstrap", "bootstrap", G.validation())
    ready()
    run = fn _ -> flunk("premature work") end
    assert {:error, :reconciliation_required} = DeliveryRuntime.dispatch(DeliveryRuntime, issue(), nil, run)
    ready()
  end

  test "scheduler restart terminates tasks and preserves the uncertain interval", c do
    saved_activation = Application.get_env(:symphony_elixir, :runtime_activation)
    on_exit(fn -> Application.put_env(:symphony_elixir, :runtime_activation, saved_activation) end)
    config = put_in(c.config.tracker.provider["item_ids"], ["item-A"]).config
    {:ok, settings} = Config.delivery_observer_settings(config)
    c = %{c | config: config, settings: settings}
    path = Workflow.workflow_file_path()
    hash = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    proof = %{"workflow" => path, "workflow_sha256" => hash, "state_root" => c.root, "launch_token" => "fixture"}
    transport = fn _, _, _, _ -> {:ok, %{"ready" => true, "reasons" => []}} end
    activation = %{settings: config, helper: "fixture", config: "fixture", proof: proof, transport: transport}
    Application.put_env(:symphony_elixir, :runtime_activation, activation)

    sup =
      start_supervised!(
        {AgentRuntimeSupervisor,
         name: __MODULE__.Supervisor,
         credentials_cache_name: nil,
         task_supervisor_name: __MODULE__.Tasks,
         orchestrator_name: __MODULE__.Scheduler,
         gate_name: __MODULE__.Gate,
         config: config,
         delivery_options: options(c)}
      )

    await(fn -> Worker.status().ready end)

    reserve()
    parent = self()

    assert {:ok, worker} =
             DeliveryRuntime.dispatch(DeliveryRuntime, issue(), nil, fn handle ->
               send(parent, {:started, handle})

               receive do
                 :finish -> :ok
               end
             end)

    assert_receive {:started, _}
    before = DeliveryRuntime.status().gate
    scheduler = Process.whereis(__MODULE__.Scheduler)
    ref = Process.monitor(worker)
    Process.exit(scheduler, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000

    next =
      await(fn ->
        pid = Process.whereis(__MODULE__.Scheduler)
        if pid && pid != scheduler, do: pid
      end)

    assert Process.alive?(next)
    snapshot = Orchestrator.snapshot(__MODULE__.Scheduler, 2_000)
    assert snapshot.delivery.gate.version.epoch != before.version.epoch
    assert snapshot.delivery.gate.state["cycle"]["budget"]["interval"] != nil
    assert snapshot.delivery.execution_enabled == true
    assert {:error, _} = DeliveryRuntime.dispatch(DeliveryRuntime, issue(), nil, fn _ -> flunk("restart duplicated work") end)
    assert Process.alive?(sup)
  end

  test "workspace and runner refuse missing permits and retain work on cancellation", c do
    {runtime, _gate} = start_runtime(c)
    reserve()
    workspace = Path.join(c.root, issue().identifier)
    File.mkdir_p!(workspace)
    marker = Path.join(workspace, "work.txt")
    File.write!(marker, "saved work")
    config = %{c.config | workspace: %{c.config.workspace | root: c.root}}
    :sys.replace_state(WorkflowStore, &%{&1 | settings: config})
    assert {:error, :delivery_permit_required} = Guard.check(nil)
    assert {:error, :delivery_permit_required} = Workspace.create_for_issue(issue())
    assert_raise RuntimeError, ~r/delivery_permit_required/, fn -> AgentRunner.run(issue()) end
    assert {:error, :workspace_cycle_retained, ""} = Workspace.remove(workspace)
    assert {:error, :workspace_cycle_retained, ""} = Workspace.remove_recorded(workspace, nil)
    outside = Path.join(Path.dirname(c.root), issue().identifier)
    assert {:error, {:workspace_outside_root, _, _}, ""} = Workspace.remove_recorded(outside, nil)
    assert {:error, :workspace_cycle_retained, ""} = Workspace.remove(workspace, "worker")
    assert File.read!(marker) == "saved work"
    assert :ok = stop_supervised(DeliveryRuntime)
    assert {:error, :delivery_runtime_unavailable} = Guard.cleanup(workspace)
    assert {:error, :delivery_runtime_unavailable} = Guard.reload(config, config)
    refute Process.alive?(runtime)
  end

  test "scheduler DOWN and legacy retry messages cannot bypass retained ownership", c do
    {runtime, _gate} = start_runtime(c)
    reserve()
    scheduler = start_supervised!({Orchestrator, name: __MODULE__.Scheduler, delivery_runtime: runtime})
    parent = self()

    {:ok, worker} =
      DeliveryRuntime.dispatch(runtime, issue(), nil, fn _ ->
        send(parent, :worker_started)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :worker_started

    :sys.replace_state(scheduler, fn state ->
      task = issue()
      ref = Process.monitor(worker)
      started = DateTime.utc_now()
      entry = %{pid: worker, ref: ref, identifier: task.identifier, issue: task, started_at: started}
      %{state | running: %{issue().id => entry}, claimed: MapSet.new([issue().id])}
    end)

    send(worker, :finish)
    await(fn -> :sys.get_state(scheduler).running == %{} end)
    assert Orchestrator.snapshot(__MODULE__.Scheduler, 2_000).retrying == []
    ready()
    token = make_ref()

    :sys.replace_state(scheduler, fn state ->
      retry = %{attempt: 1, retry_token: token, identifier: issue().identifier}
      %{state | retry_attempts: %{issue().id => retry}, claimed: MapSet.new([issue().id])}
    end)

    send(scheduler, {:retry_issue, issue().id, token})
    state = Orchestrator.snapshot(__MODULE__.Scheduler, 2_000)
    assert state.retrying == []
    assert state.running == []
    assert state.delivery.gate.state["cycle"]["owner"]["item_id"] == issue().id
    assert :ok = stop_supervised(DeliveryRuntime)
    assert Orchestrator.snapshot(__MODULE__.Scheduler, 2_000).delivery.reason == :delivery_runtime_unavailable
  end

  test "workflow reload failure revokes the active worker instead of silently using old settings", c do
    {runtime, _gate} = start_runtime(c)
    reserve()
    parent = self()

    {:ok, pid} =
      DeliveryRuntime.dispatch(runtime, issue(), nil, fn handle ->
        send(parent, {:guard, Guard.check(handle), Guard.command("printf ok", handle)})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:guard, :ok, {:ok, command}}
    assert command =~ "SYMPHONY_DELIVERY_CONTEXT"
    :sys.replace_state(WorkflowStore, &%{&1 | settings: c.config})
    File.write!(Workflow.workflow_file_path(), "---\ninvalid: [\n---\n")
    assert {:error, _} = WorkflowStore.force_reload()
    await(fn -> DeliveryRuntime.status(runtime).worker == nil end)
    refute Process.alive?(pid)
    assert DeliveryRuntime.status(runtime).restart_required
    assert Config.settings!().tracker.kind == "github_projects"
    # A valid replacement cannot change the identity/scope underneath a retained cycle.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 1234)
    assert {:error, :restart_required} = WorkflowStore.force_reload()
    # Missing files use the same stop path as malformed content.
    File.rm!(Workflow.workflow_file_path())
    assert {:error, :enoent} = WorkflowStore.force_reload()
  end
end
