defmodule SymphonyElixir.DeliveryRuntimeIntegrationTest do
  use SymphonyElixir.TestSupport
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{AgentRuntimeSupervisor, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.DeliveryRuntime.Guard
  alias SymphonyElixir.GitHubProjects.Delivery.Observation

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

  defp start_runtime(c) do
    gate = start_supervised!({DeliveryGate, settings: c.settings.gate})
    tasks = start_supervised!(Task.Supervisor)
    opts = [name: DeliveryRuntime, config: c.config, gate: gate, task_supervisor: tasks] ++ options(c)
    runtime = start_supervised!({DeliveryRuntime, opts})
    {runtime, gate}
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
    sup =
      start_supervised!(
        {AgentRuntimeSupervisor,
         name: __MODULE__.Supervisor,
         credentials_cache_name: nil,
         task_supervisor_name: __MODULE__.Tasks,
         orchestrator_name: __MODULE__.Scheduler,
         gate_name: __MODULE__.Gate,
         config: c.config,
         delivery_options: options(c)}
      )

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
    assert snapshot.delivery.execution_enabled == false
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
