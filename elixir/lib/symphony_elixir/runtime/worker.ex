defmodule SymphonyElixir.Runtime.Worker do
  @moduledoc "Supervised runtime readiness and immutable per-interval SSH bindings. The delivery gate owns work."
  use GenServer
  alias SymphonyElixir.{DeliveryRuntime, WorkerTransport}
  alias SymphonyElixir.GitHub.Credentials

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{ready: false, reasons: [:worker_runtime_unavailable]}
  end

  @spec prepare(map()) :: {:ok, String.t()} | {:error, term()}
  def prepare(handle) do
    with :ok <- DeliveryRuntime.check(handle, :effect),
         {:ok, config, activation} <- GenServer.call(__MODULE__, {:bind, handle}),
         {:ok, token} <- credential(config, activation),
         :ok <- DeliveryRuntime.check(handle, :effect),
         {:ok, _} <- exchange(activation, %{"action" => "prepare", "context" => handle.context, "token" => token}),
         :ok <- DeliveryRuntime.check(handle, :effect),
         remaining = handle.deadline - System.monotonic_time(:millisecond),
         {:ok, proof} <- exchange(activation, Map.put(request(handle, "start"), "active_ms", remaining)),
         :ok <- GenServer.call(__MODULE__, {:started, handle, proof}),
         :ok <- DeliveryRuntime.check(handle, :effect),
         :ok <- login_probe(proof["host"], handle, activation, 5) do
      {:ok, proof["host"]}
    else
      {:error, reason} when reason in [:codex_login_required, :worker_probe_failed] ->
        GenServer.call(__MODULE__, {:admission_block, handle, reason})
        {:error, :isolated_worker_start_unconfirmed}

      _ ->
        {:error, :isolated_worker_start_unconfirmed}
    end
  end

  @spec endpoint(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def endpoint(host), do: GenServer.call(__MODULE__, {:endpoint, host})

  @spec workspace(map(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def workspace(handle, host), do: GenServer.call(__MODULE__, {:workspace, handle, host})

  @spec model_selection(map()) :: {:ok, map()} | {:error, atom()}
  def model_selection(handle), do: GenServer.call(__MODULE__, {:model_selection, handle})

  @spec model_applied(map(), map()) :: :ok | {:error, term()}
  def model_applied(handle, choice) do
    with :ok <- DeliveryRuntime.check(handle, :effect),
         {:ok, activation} <- GenServer.call(__MODULE__, :activation),
         {:ok, %{"applied" => ^choice}} <- exchange(activation, Map.put(request(handle, "model_applied"), "selection", choice)),
         do: GenServer.call(__MODULE__, {:model_applied, handle, choice})
  end

  @spec model_rejected(map(), atom()) :: {:error, atom()}
  def model_rejected(handle, reason) do
    GenServer.call(__MODULE__, {:admission_block, handle, reason})
    {:error, reason}
  end

  @spec stop(map()) :: :stopped | :stop_unconfirmed
  def stop(worker) do
    handle = worker.handle

    with {:ok, activation} <- GenServer.call(__MODULE__, {:revoke, handle}),
         {:ok, %{"phase" => "stopped"}} <- stop_exchange(activation, request(handle, "stop"), 3) do
      GenServer.call(__MODULE__, {:stopped, handle})
      :stopped
    else
      _ -> :stop_unconfirmed
    end
  catch
    :exit, _ -> :stop_unconfirmed
  end

  @spec export(map(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def export(cycle, sha) do
    request = %{"action" => "export_cycle", "cycle" => cycle["id"], "branch" => cycle["work"]["branch"], "sha" => sha}

    with {:ok, activation} <- GenServer.call(__MODULE__, :activation),
         {:ok, %{"path" => path, "sha" => ^sha}} <- exchange(activation, request),
         do: {:ok, path}
  end

  @spec request(map(), String.t()) :: map()
  def request(handle, action) do
    %{"action" => action, "cycle" => handle.context["cycle_id"], "interval" => handle.context["interval_id"], "generation" => handle.context["interval_id"]}
  end

  @spec exchange(map(), map()) :: {:ok, map()} | {:error, atom()}
  def exchange(activation, request) do
    timeout = if request["action"] in ["prepare", "export_cycle"], do: 300_000, else: 90_000
    transport = Map.get(activation, :transport, &WorkerTransport.exchange/4)
    transport.(activation.helper, activation.config, request, timeout)
  end

  defp credential(config, activation) do
    read =
      Map.get(activation, :credential, fn ->
        with {:ok, reference} <- Credentials.reference(config.tracker.provider, :delivery_read),
             do: Credentials.token(reference)
      end)

    read.()
  end

  defp login_probe(host, handle, activation, attempts) do
    probe = Map.get(activation, :probe, &SymphonyElixir.SSH.probe/3)

    with :ok <- DeliveryRuntime.check(handle, :effect) do
      case probe.(host, "codex login status", 5_000) do
        :ok ->
          :ok

        {:error, :codex_login_required} = error ->
          error

        _ when attempts > 1 ->
          Process.sleep(200)
          login_probe(host, handle, activation, attempts - 1)

        _ ->
          {:error, :worker_probe_failed}
      end
    end
  end

  @impl true
  def init(opts) do
    state = %{
      activation: Keyword.fetch!(opts, :activation),
      config: Keyword.fetch!(opts, :config),
      tasks: Keyword.fetch!(opts, :tasks),
      runtime: Keyword.fetch!(opts, :runtime),
      active: nil,
      pending: nil,
      started: false,
      closing: false,
      finishing: false,
      model_block: nil,
      timer: nil,
      report: %{ready: false, reasons: [:worker_reconciliation_required]}
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _, %{pending: pending, active: active} = state) when not is_nil(pending) and (is_nil(active) or active.phase == :stopped),
    do: {:reply, %{state.report | ready: false}, state}

  def handle_call(:status, _, %{model_block: reason} = state) when not is_nil(reason),
    do: {:reply, Map.merge(state.report, %{ready: false, reasons: [reason], model: %{"selected" => get_in(state.report, [:model, "selected"]), "applied" => nil}}), state}

  def handle_call(:status, _, state), do: {:reply, state.report, state}
  def handle_call(:activation, _, state), do: {:reply, {:ok, state.activation}, state}

  def handle_call({:bind, handle}, {pid, _}, state) do
    if not state.closing and state.model_block == nil and state.pending == nil and state.report.ready and (state.active == nil or state.active.phase == :stopped) do
      active = %{handle: handle, phase: :preparing, endpoint: nil, pid: pid, monitor: Process.monitor(pid)}
      {:reply, {:ok, state.config, state.activation}, %{state | active: active}}
    else
      {:reply, {:error, :worker_not_ready}, state}
    end
  end

  def handle_call({:started, handle, proof}, {pid, _}, %{active: %{handle: handle, pid: pid, phase: :preparing} = active} = state) do
    valid =
      proof["cycle"] == handle.context["cycle_id"] and proof["interval"] == handle.context["interval_id"] and
        proof["generation"] == handle.context["interval_id"] and proof["workspace"] == "/workspace/repo" and
        proof["host"] == "symphony-task-" <> handle.context["interval_id"] and is_binary(proof["ssh_config"])

    if valid do
      send(self(), :poll)
      {:reply, :ok, %{state | active: %{active | phase: :running, endpoint: proof}}}
    else
      {:reply, {:error, :worker_binding_changed}, state}
    end
  end

  def handle_call({:endpoint, host}, _, %{active: %{phase: :running, endpoint: %{"host" => host, "ssh_config" => config}}} = state),
    do: {:reply, {:ok, config}, state}

  def handle_call({:workspace, handle, host}, _, %{active: %{handle: handle, phase: :running, endpoint: %{"host" => host}}} = state),
    do: {:reply, {:ok, "/workspace/repo"}, state}

  def handle_call({:model_selection, handle}, {pid, _}, %{active: %{handle: handle, pid: pid, phase: :running, endpoint: %{"selection" => choice}}} = state),
    do: {:reply, {:ok, choice}, state}

  def handle_call({:model_applied, handle, choice}, {pid, _}, %{active: %{handle: handle, pid: pid, phase: :running, endpoint: %{"selection" => choice}}} = state),
    do: {:reply, :ok, %{state | report: Map.put(state.report, :model, %{"selected" => choice, "applied" => choice})}}

  def handle_call({:admission_block, handle, reason}, {pid, _}, %{active: %{handle: handle, pid: pid}} = state),
    do: {:reply, :ok, %{state | model_block: reason}}

  def handle_call({:revoke, handle}, _, %{active: %{handle: handle} = active} = state),
    do: {:reply, {:ok, state.activation}, %{state | active: %{active | phase: :stopping}}}

  def handle_call({:stopped, handle}, _, %{active: %{handle: handle} = active} = state) do
    Process.demonitor(active.monitor, [:flush])
    send(self(), :poll)
    {:reply, :ok, %{state | active: %{active | phase: :stopped}}}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :worker_binding_changed}, state}

  @impl true
  def handle_info(:poll, %{pending: nil} = state) do
    state = state |> schedule_poll() |> check_shutdown_request()

    action =
      cond do
        state.finishing -> nil
        not state.started -> %{"action" => "recover"}
        state.active && state.active.phase == :running -> request(state.active.handle, "heartbeat")
        state.active && state.active.phase in [:preparing, :stopping] -> nil
        true -> %{"action" => "status"}
      end

    if action do
      task = Task.Supervisor.async_nolink(state.tasks, fn -> exchange(state.activation, action) end)
      {:noreply, %{state | pending: %{task: task, action: action}}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:poll, state) do
    {:noreply, state |> schedule_poll() |> check_shutdown_request()}
  end

  def handle_info({:runtime_quiescent, last}, %{pending: nil, finishing: false} = state) do
    report = completion_report(last, state.config.tracker.provider["repo"])
    action = %{"action" => "finish", "report" => report, "pilot_finished" => last != nil}
    task = Task.Supervisor.async_nolink(state.tasks, fn -> exchange(state.activation, action) end)
    {:noreply, %{state | pending: %{task: task, action: action}, finishing: true, closing: true}}
  end

  def handle_info({ref, result}, %{pending: %{task: %{ref: ref}, action: action}} = state) do
    Process.demonitor(ref, [:flush])
    next = %{state | pending: nil}

    case result do
      {:ok, proof} ->
        report = runtime_report(action["action"], proof, state.report)

        if action["action"] == "heartbeat" and not report.ready, do: send(state.runtime, :runtime_worker_lost)
        {:noreply, %{next | report: report, started: true}}

      _ ->
        if state.active && state.active.phase == :running, do: send(state.runtime, :runtime_worker_lost)
        {:noreply, %{next | finishing: false, report: %{ready: false, reasons: [:worker_runtime_unavailable]}}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{pending: %{task: %{ref: ref}}} = state) do
    if state.active && state.active.phase == :running, do: send(state.runtime, :runtime_worker_lost)
    report = %{ready: false, reasons: [:worker_runtime_unavailable]}
    {:noreply, %{state | pending: nil, finishing: false, report: report}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{active: %{monitor: ref} = active} = state),
    do: {:noreply, %{state | active: %{active | phase: :stopping}}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(_), do: %{state: :runtime_worker_redacted}

  defp runtime_report("finish", _, previous), do: previous

  defp runtime_report(_, proof, previous) do
    %{
      ready: proof["ready"] == true,
      reasons: proof["reasons"] || [],
      storage: Map.take(proof, ~w(controller_disk worker_disk)),
      auth_present: proof["auth_present"],
      model: proof["model"] || Map.get(previous, :model, %{})
    }
  end

  defp schedule_poll(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :poll, 10_000)}
  end

  defp stop_exchange(activation, request, remaining) do
    case exchange(activation, request) do
      {:ok, _} = result ->
        result

      _ when remaining > 1 ->
        Process.sleep(1_000)
        stop_exchange(activation, request, remaining - 1)

      error ->
        error
    end
  end

  defp check_shutdown_request(%{closing: true} = state), do: state

  defp check_shutdown_request(state) do
    path = Path.join(state.activation.proof["state_root"], "shutdown.request")

    with {:ok, raw} <- File.read(path), true <- byte_size(raw) < 1024, {:ok, %{"token" => token}} <- Jason.decode(raw), true <- token == state.activation.proof["launch_token"] do
      :ok = DeliveryRuntime.shutdown(state.runtime)
      %{state | closing: true}
    else
      _ -> state
    end
  end

  defp completion_report(nil, _), do: nil

  defp completion_report(last, repo) do
    %{
      "cycle" => last["id"],
      "repo" => repo,
      "outcome" => if(last["phase"] in ~w(completed recovered), do: "completed", else: "cancelled"),
      "phase" => last["phase"],
      "task" => Map.take(last["task"] || %{}, ~w(item_id issue_id repo)),
      "work" => Map.take(last["work"] || %{}, ~w(branch base_sha head_sha pr_number)),
      "deployment" => Map.take(last["deployment"] || %{}, ~w(sha run_id run_attempt result)),
      "budget" => Map.take(last["budget"] || %{}, ~w(initial_ms fix_ms fixes accounting_uncertain limits))
    }
  end
end
