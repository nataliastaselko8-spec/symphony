defmodule SymphonyElixir.RuntimeWorkerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ModelSelection
  alias SymphonyElixir.Runtime.{Activation, Worker}
  alias SymphonyElixir.SSH

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    {:ok, replies} = Agent.start_link(fn -> %{} end)
    parent = self()

    transport = fn _, _, request, _ ->
      send(parent, {:request, self(), request})

      case Agent.get(replies, &Map.get(&1, request["action"])) do
        nil ->
          {:ok, %{"ready" => true, "reasons" => [], "auth_present" => true}}

        :wait ->
          receive do
            {:reply, result} -> result
          end

        fun when is_function(fun) ->
          fun.(request)

        value ->
          value
      end
    end

    proof = %{"state_root" => root, "launch_token" => "fixture"}
    activation = %{helper: "fixture", config: "fixture", settings: Config.settings!(), proof: proof, transport: transport}
    tasks = start_supervised!(Task.Supervisor)
    options = [activation: activation, config: Config.settings!(), tasks: tasks, runtime: parent]
    worker = start_supervised!({Worker, options})
    wait_ready(worker)
    %{worker: worker, replies: replies, root: root, activation: activation}
  end

  defp wait_ready(worker, attempts \\ 200)
  defp wait_ready(_, 0), do: flunk("worker readiness did not settle")

  defp wait_ready(worker, n) do
    if Worker.status(worker).ready,
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_ready(worker, n - 1)
        )
  end

  defp handle(id \\ "one"), do: %{context: %{"cycle_id" => "cycle", "interval_id" => id}}

  defp bind(worker, handle) do
    assert {:ok, _, _} = GenServer.call(worker, {:bind, handle})

    proof = %{
      "cycle" => "cycle",
      "interval" => handle.context["interval_id"],
      "generation" => handle.context["interval_id"],
      "workspace" => "/workspace/repo",
      "host" => "symphony-task-" <> handle.context["interval_id"],
      "ssh_config" => "/private/pinned",
      "selection" => %{"model" => "fixture", "effort" => "high"}
    }

    assert :ok = GenServer.call(worker, {:started, handle, proof})
    proof
  end

  test "endpoint is bound to one interval and revoked before stop acknowledgement", c do
    assert {:error, :worker_binding_changed} = Worker.endpoint("symphony-task-absent")
    h = handle()
    assert {:ok, _, _} = GenServer.call(c.worker, {:bind, h})
    assert {:error, :worker_binding_changed} = Worker.endpoint("symphony-task-one")
    assert {:error, :worker_binding_changed} = GenServer.call(c.worker, {:started, h, %{}})
    proof = %{"cycle" => "cycle", "interval" => "one", "generation" => "one", "workspace" => "/workspace/repo", "host" => "symphony-task-one", "ssh_config" => "/private/pinned"}
    assert :ok = GenServer.call(c.worker, {:started, h, proof})
    assert {:ok, "/private/pinned"} = Worker.endpoint(proof["host"])
    assert {:ok, "/workspace/repo"} = Worker.workspace(h, proof["host"])
    assert {:error, :worker_binding_changed} = Worker.workspace(handle("old"), proof["host"])
    assert {:error, :worker_not_ready} = GenServer.call(c.worker, {:bind, handle("two")})
    Agent.update(c.replies, &Map.put(&1, "stop", :wait))
    task = Task.async(fn -> Worker.stop(%{handle: h}) end)
    assert_receive {:request, pid, %{"action" => "stop", "generation" => "one"}}, 1000
    assert {:error, :worker_binding_changed} = Worker.endpoint(proof["host"])
    assert Worker.status(c.worker).ready
    send(pid, {:reply, {:ok, %{"phase" => "stopped"}}})
    assert Task.await(task) == :stopped
    wait_ready(c.worker)
    assert {:ok, _, _} = GenServer.call(c.worker, {:bind, handle("two")})
    assert Worker.stop(%{handle: h}) == :stop_unconfirmed
  end

  test "model catalog pagination rejects missing effort, ambiguity, hidden models and invalid cursors", c do
    h = Map.put(handle(), :isolated, true)
    bind(c.worker, h)
    choice = %{"model" => "fixture", "effort" => "high"}
    row = %{"model" => "fixture", "supportedReasoningEfforts" => [%{"reasoningEffort" => "high", "description" => "More thinking"}]}
    assert ModelSelection.thread_params(choice) == %{"model" => "fixture", "config" => %{"model_reasoning_effort" => "high"}}
    assert ModelSelection.turn_params(choice) == choice
    assert ModelSelection.supported(choice, [row]) == :ok
    assert ModelSelection.supported(%{}, []) == {:error, :model_selection_required}
    assert ModelSelection.supported(choice, [row, row]) == {:error, :selected_model_unavailable}
    assert ModelSelection.supported(choice, [Map.put(row, "hidden", true)]) == {:error, :selected_model_unavailable}
    assert ModelSelection.supported(%{choice | "effort" => "unsupported"}, [row]) == {:error, :selected_effort_unavailable}
    assert {:ok, ^choice} = ModelSelection.load(%{delivery: h}, fn _ -> {:ok, %{"data" => [row], "nextCursor" => nil}} end)

    for rpc <- [
          fn _ -> {:ok, %{"data" => [Map.put(row, "supportedReasoningEfforts", [])]}} end,
          fn _ -> {:ok, %{"data" => []}} end,
          fn _ -> {:ok, %{"data" => "invalid"}} end,
          fn _ -> {:error, :offline} end,
          fn _ -> {:ok, %{"data" => [], "nextCursor" => "repeated"}} end,
          fn params -> {:ok, %{"data" => [], "nextCursor" => (params["cursor"] || "") <> "x"}} end
        ] do
      assert {:error, _} = ModelSelection.load(%{delivery: h}, rpc)
      refute Worker.status(c.worker).ready
    end

    assert {:error, _} = ModelSelection.load(%{delivery: %{h | context: %{"cycle_id" => "stale", "interval_id" => "stale"}}}, fn _ -> flunk("stale handle reached model/list") end)
  end

  test "stop transport retries are bounded and failure keeps endpoint revoked", c do
    h = handle()
    bind(c.worker, h)
    Agent.update(c.replies, &Map.put(&1, "stop", {:error, :offline}))
    assert Worker.stop(%{handle: h}) == :stop_unconfirmed
    assert {:error, _} = Worker.endpoint("symphony-task-one")
    for _ <- 1..3, do: assert_receive({:request, _, %{"action" => "stop"}}, 1000)
    refute_receive {:request, _, %{"action" => "stop"}}
  end

  test "delayed heartbeat cannot block status and low disk revokes work", c do
    Agent.update(c.replies, &Map.put(&1, "heartbeat", :wait))
    bind(c.worker, handle())
    assert_receive {:request, pid, %{"action" => "heartbeat"}}, 1000
    send(c.worker, :poll)
    assert Worker.status(c.worker).ready
    send(pid, {:reply, {:ok, %{"ready" => false, "reasons" => ["disk_space_low"], "worker_disk" => %{"free_bytes" => 1}}}})
    assert_receive :runtime_worker_lost
    assert Worker.status(c.worker).reasons == ["disk_space_low"]
  end

  test "lost heartbeat and owner DOWN keep endpoints closed", c do
    Agent.update(c.replies, &Map.put(&1, "heartbeat", {:error, :lost}))
    parent = self()

    owner =
      spawn(fn ->
        bind(c.worker, handle())
        send(parent, :bound)

        receive do
          :exit -> :ok
        end
      end)

    assert_receive :bound
    assert_receive :runtime_worker_lost, 1000
    send(owner, :exit)
    Process.sleep(20)
    assert {:error, _} = Worker.endpoint("symphony-task-one")
    refute Worker.status(c.worker).ready
    send(c.worker, :unknown)
    assert Worker.status(c.worker)
  end

  test "transport task crash is a closed admission, not a supervisor crash", c do
    Agent.update(c.replies, &Map.put(&1, "heartbeat", fn _ -> exit(:transport_crashed) end))
    bind(c.worker, handle())
    assert_receive :runtime_worker_lost, 1000
    assert Worker.status(c.worker).reasons == [:worker_runtime_unavailable]
    assert Process.alive?(c.worker)
  end

  test "export uses saved controller binding after local process restart", c do
    Agent.update(c.replies, &Map.put(&1, "export_cycle", fn request -> {:ok, %{"path" => "/private/export.bundle", "sha" => request["sha"]}} end))
    assert {:ok, "/private/export.bundle"} = Worker.export(%{"id" => "cycle", "work" => %{"branch" => "agent/task"}}, "sha")
    assert_receive {:request, _, %{"action" => "export_cycle", "branch" => "agent/task"}}
    assert Worker.request(handle(), "stop")["generation"] == "one"
  end

  test "final summary distinguishes successful completion from cancellation", c do
    send(c.worker, {:runtime_quiescent, %{"id" => "cycle", "phase" => "completed", "budget" => %{"initial_ms" => 10}}})
    assert_receive {:request, _, %{"action" => "finish", "pilot_finished" => true, "report" => report}}, 1000
    assert report["outcome"] == "completed"
    assert report["budget"]["initial_ms"] == 10
    assert {:error, :worker_not_ready} = GenServer.call(c.worker, {:bind, handle()})
    assert Worker.format_status(%{}) == %{state: :runtime_worker_redacted}
  end

  test "failed finish is retried without declaring shutdown complete", c do
    Agent.update(c.replies, &Map.put(&1, "finish", {:error, :lost}))
    send(c.worker, {:runtime_quiescent, %{"id" => "cycle", "phase" => "cancelled"}})
    assert_receive {:request, _, %{"action" => "finish", "report" => %{"outcome" => "cancelled"}}}, 1000
    Process.sleep(20)
    send(c.worker, {:runtime_quiescent, nil})
    assert_receive {:request, _, %{"action" => "finish", "pilot_finished" => false, "report" => nil}}, 1000
  end

  test "unavailable runtime cannot route reserved SSH alias or retain an activation", c do
    stop_supervised(Worker)
    refute Worker.status(c.worker).ready
    assert Worker.stop(%{handle: handle()}) == :stop_unconfirmed
    assert {:error, :isolated_worker_unavailable} = SSH.run("symphony-task-one", "echo forbidden")
    assert {:error, :isolated_worker_start_unconfirmed} = Worker.prepare(%{runtime: c.worker})
    previous = Application.get_env(:symphony_elixir, :runtime_activation)
    on_exit(fn -> Application.put_env(:symphony_elixir, :runtime_activation, previous) end)
    Application.put_env(:symphony_elixir, :runtime_activation, %{settings: :old})
    assert {:error, :github_projects_execution_disabled} = Activation.validate_settings(:new)
    assert Activation.current() == nil
  end
end
