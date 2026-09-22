defmodule SymphonyElixir.StatusSyncRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGate.StatusSync
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.Observation

  setup do
    root = Path.join(System.tmp_dir!(), "status-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    f = F.fixture()
    roles = Map.merge(f.settings.project.states, %{"review" => "Human review", "dev_validation" => "Dev validation", "production_ready" => "Ready for production"})
    raw = f.raw |> put_in(["delivery", "state_path"], Path.join(root, "delivery.json")) |> put_in(["tracker", "provider", "states"], roles)
    {:ok, config} = Config.Schema.parse(raw)
    {:ok, settings} = Config.delivery_observer_settings(config)
    gate = start_supervised!({DeliveryGate, settings: settings.gate})
    tasks = start_supervised!(Task.Supervisor)
    cache = start_supervised!(F.Cache)
    remote = start_supervised!({Agent, fn -> %{status: "Dev validation", writes: 0, wait: false} end})

    opts = [
      credentials_cache: cache,
      project_reader: fn _, _ ->
        value = Agent.get(remote, & &1)

        if value.wait,
          do:
            (receive do
               :continue -> :ok
             end)

        {:ok,
         %{
           "project" => %{"id" => "project", "repo" => settings.repo},
           "items" => [
             %{
               "item_id" => "item-A",
               "state" => value.status,
               "archived" => false,
               "in_scope" => true,
               "reasons" => [],
               "issue_state" => "OPEN",
               "native_ref" => %{"issue_id" => "issue-A", "repo" => settings.repo, "agent_allowed_option_id" => "yes"}
             }
           ],
           "schema" => %{"agent_allowed_option_id" => "yes", "status" => %{"id" => "status", "options" => Enum.map(roles, fn {id, name} -> %{"id" => id, "name" => name} end)}}
         }}
      end,
      observer: fn _, options ->
        {:ok,
         Observation.new(
           settings,
           options[:context],
           %{"pr" => %{"state" => "merged", "number" => 7, "merge_sha" => G.sha("c"), "ancestry" => "included"}, "dev_sha" => G.sha("c"), "deployment" => G.deployment()},
           []
         )}
      end,
      http: fn options ->
        assert options[:json]["query"] =~ "SymphonyStatus"
        assert options[:json]["variables"]["input"]["value"]["singleSelectOptionId"] == "production_ready"
        Agent.update(remote, &%{&1 | status: "Ready for production", writes: &1.writes + 1})
        F.ok(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "item-A"}}}})
      end
    ]

    c = %{root: root, config: config, settings: settings, gate: gate, tasks: tasks, remote: remote, opts: opts}

    for {action, args} <- [
          {"bootstrap", G.validation()},
          {"reserve", G.task()},
          {"reserve_ci", G.ci_request()},
          {"observe_ci", G.ci_result()},
          {"handoff", %{"pr_number" => 7, "sha" => G.sha("b")}},
          {"merged", %{"pr_number" => 7, "sha" => G.sha("c")}},
          {"deployment", G.deployment()},
          {"validate_dev", G.passed()}
        ] do
      assert {:ok, _} = execute(c, action, args)
    end

    args = %{"action" => "complete", "args" => G.proof("c"), "from" => "Dev validation", "repo" => settings.repo, "reason" => "Validated exact deployment"}
    assert {:ok, _} = execute(c, "status_transition", args)
    c
  end

  defp execute(c, action, args) do
    version = DeliveryGate.status(c.gate).version
    sha = if action == "status_transition", do: args["args"]["sha"], else: args["sha"] || G.sha()
    DeliveryGate.reconcile(c.gate, version, c.settings.gate.scope, sha)
    DeliveryGate.execute(c.gate, version, "cmd-#{System.unique_integer([:positive])}", action, args)
  end

  defp runtime(c) do
    opts = [config: c.config, gate: c.gate, task_supervisor: c.tasks, status_options: c.opts]
    observer = fn _, _ -> {:error, :fixture_offline} end
    start_supervised!({DeliveryRuntime, opts ++ [observer: observer, checkpoint_ms: 10]})
  end

  defp await(fun, attempts \\ 200)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, n - 1)
        )
  end

  test "restart after complete resumes the stored intent without starting worker or publication", c do
    assert DeliveryGate.status(c.gate).state["cycle"] == nil
    assert StatusSync.pending?(DeliveryGate.status(c.gate).state)
    stop_supervised!(DeliveryGate)
    gate = start_supervised!({DeliveryGate, settings: c.settings.gate})
    c = %{c | gate: gate}
    runtime = runtime(c)
    await(fn -> not StatusSync.pending?(DeliveryGate.status(gate).state) end)
    assert Agent.get(c.remote, & &1.writes) == 1
    assert DeliveryRuntime.status(runtime).worker == nil
    assert :sys.get_state(runtime).effect == nil
    [op] = DeliveryRuntime.status(runtime).status_sync
    assert op["status"] == "confirmed" and op["confirmed_at_ms"] > 0
    assert {:ok, _} = File.read(c.settings.gate.path)
    assert :ok = DeliveryRuntime.shutdown(runtime)
  end

  test "restart after saved send reconciles an accepted remote write without a second mutation", c do
    [op] = StatusSync.operations(DeliveryGate.status(c.gate).state)
    version = DeliveryGate.status(c.gate).version
    args = %{"operation_id" => op["id"], "outcome" => "sent", "observed" => "Dev validation", "error" => nil, "at_ms" => 1, "retry_at_ms" => 0}
    assert {:ok, _} = DeliveryGate.execute(c.gate, version, "sent", "status_result", args)
    Agent.update(c.remote, &%{&1 | status: "Ready for production", writes: 1})
    stop_supervised!(DeliveryGate)
    gate = start_supervised!({DeliveryGate, settings: c.settings.gate})
    runtime = runtime(%{c | gate: gate})
    await(fn -> not StatusSync.pending?(DeliveryGate.status(gate).state) end)
    assert Agent.get(c.remote, & &1.writes) == 1
    assert {:error, :status_send_revoked} = GenServer.call(runtime, {:status_send, op["id"]})
  end

  test "bounded request timeout retains intent; shutdown never drops it", c do
    Agent.update(c.remote, &%{&1 | wait: true})
    runtime = runtime(c)
    await(fn -> :sys.get_state(runtime).status_task != nil end)
    record = :sys.get_state(runtime).status_task
    send(runtime, {:status_timeout, record.task.ref})
    await(fn -> :sys.get_state(runtime).status_task == nil end)
    [op] = StatusSync.operations(DeliveryGate.status(c.gate).state)
    assert op["status"] == "unknown" and op["error"] == "status_request_timeout"
    assert op["retry_at_ms"] > System.system_time(:millisecond)
    assert :ok = DeliveryRuntime.shutdown(runtime)
    assert StatusSync.pending?(DeliveryGate.status(c.gate).state)
    assert Agent.get(c.remote, & &1.writes) == 0
  end

  test "a crashed sync task retains the intent and exposes its failure", c do
    Agent.update(c.remote, &%{&1 | wait: true})
    runtime = runtime(c)
    await(fn -> :sys.get_state(runtime).status_task != nil end)
    Process.exit(:sys.get_state(runtime).status_task.task.pid, :kill)
    await(fn -> :sys.get_state(runtime).status_task == nil end)
    [op] = StatusSync.operations(DeliveryGate.status(c.gate).state)
    assert op["status"] == "unknown" and op["error"] == "status_task_failed"
    assert StatusSync.pending?(DeliveryGate.status(c.gate).state)
    assert Agent.get(c.remote, & &1.writes) == 0
  end

  test "reload and changed journal revision revoke an in-flight task before mutation", c do
    Agent.update(c.remote, &%{&1 | wait: true})
    runtime = runtime(c)
    assert :ok = DeliveryRuntime.check_settings(runtime, c.config)
    await(fn -> :sys.get_state(runtime).status_task != nil end)
    task = :sys.get_state(runtime).status_task.task
    [op] = StatusSync.operations(DeliveryGate.status(c.gate).state)
    args = %{"operation_id" => op["id"], "outcome" => "retry", "observed" => nil, "error" => nil, "at_ms" => 1, "retry_at_ms" => 0}
    assert {:ok, _} = DeliveryGate.execute(c.gate, DeliveryGate.status(c.gate).version, "intervening", "status_result", args)
    Agent.update(c.remote, &%{&1 | wait: false})
    send(task.pid, :continue)
    await(fn -> :sys.get_state(runtime).status_task == nil end)
    assert Agent.get(c.remote, & &1.writes) == 0
    assert hd(StatusSync.operations(DeliveryGate.status(c.gate).state))["status"] == "retry"
  end

  test "pending status holds a queued report and shutdown revokes sending", c do
    settings = %{c.settings | gate: %{c.settings.gate | path: Path.join(c.root, "other.json")}}
    gate = start_supervised!(%{id: :other_gate, start: {DeliveryGate, :start_link, [[settings: settings.gate]]}})
    other = %{c | gate: gate, settings: settings}

    for {action, args} <- [
          {"bootstrap", G.validation()},
          {"reserve", G.task()},
          {"start_work", %{"interval_id" => "w", "budget" => "initial"}},
          {"effect_request", %{"operation_id" => "comment", "kind" => "report", "payload" => %{"body" => "Failure report"}}},
          {"stop_work", %{"interval_id" => "w", "elapsed_ms" => 25}}
        ] do
      assert {:ok, _} = execute(other, action, args)
    end

    args = %{"action" => "block", "args" => %{"reason" => "Worker failed"}, "from" => "Agent working", "repo" => settings.repo, "reason" => "Stop confirmed"}
    assert {:ok, _} = execute(other, "status_transition", args)
    Agent.update(c.remote, &%{&1 | wait: true, status: "Agent working"})
    runtime = runtime(other)
    await(fn -> :sys.get_state(runtime).status_task != nil end)
    assert :sys.get_state(runtime).effect == nil
    assert :ok = DeliveryRuntime.shutdown(runtime)
    task = :sys.get_state(runtime).status_task.task
    Agent.update(c.remote, &%{&1 | wait: false})
    send(task.pid, :continue)
    await(fn -> :sys.get_state(runtime).status_task == nil end)
    assert Agent.get(c.remote, & &1.writes) == 0
    assert StatusSync.pending?(DeliveryGate.status(gate).state)
    assert DeliveryGate.status(gate).state["cycle"]["effects"]["comment"]["steps"] == %{}
  end
end
