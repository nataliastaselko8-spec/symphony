defmodule SymphonyElixir.DeliveryRuntime do
  @moduledoc "Controller lifecycle coordinator. Projects live execution remains disabled at application entry points."

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, DeliveryGate}
  alias SymphonyElixir.DeliveryRuntime.{HookContext, Policy}
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.Observation

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec dispatch(GenServer.server(), map(), String.t() | nil, (map() -> term())) :: {:ok, pid()} | {:error, atom()}
  def dispatch(server, issue, host, run), do: GenServer.call(server, {:dispatch, issue, host, run}, 30_000)

  @spec check(map(), :activate | :continue | :effect) :: :ok | {:error, atom()}
  def check(%{runtime: runtime} = handle, mode \\ :continue) do
    with :ok <- GenServer.call(runtime, {:check, handle, mode}, 15_000) do
      DeliveryGate.worker_check(handle.gate, handle.nonce, :continue)
    end
  catch
    :exit, _ -> {:error, :delivery_runtime_unavailable}
  end

  @spec pause(GenServer.server(), String.t()) :: :ok
  def pause(server, reason), do: GenServer.call(server, {:pause, reason}, 15_000)

  @doc "Trusted controller only; operator authentication belongs to PR-10."
  @spec command(GenServer.server(), map(), String.t(), String.t(), map()) :: term()
  def command(server, version, id, action, args),
    do: GenServer.call(server, {:command, version, id, action, args}, 30_000)

  @spec check_settings(GenServer.server(), Config.Schema.t()) :: :ok | {:error, atom()}
  def check_settings(server, config), do: GenServer.call(server, {:settings, config}, 15_000)

  @spec cleanup(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def cleanup(server, path), do: GenServer.call(server, {:cleanup, path})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)

    with {:ok, settings} <- Config.delivery_observer_settings(config) do
      now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)

      state = %{
        config: config,
        settings: settings,
        gate: Keyword.fetch!(opts, :gate),
        opts: opts,
        tasks: Keyword.fetch!(opts, :task_supervisor),
        now: now,
        observation: nil,
        observed_at: nil,
        worker: nil,
        read: nil,
        next_read_at: now.(),
        retry_at: now.(),
        reason: :reconciliation_required,
        restart: false
      }

      send(self(), :observe)
      schedule_tick(opts)
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    worker = if state.worker, do: Map.take(state.worker, [:item, :interval, :status, :elapsed_ms, :effects]), else: nil

    result = %{
      gate: DeliveryGate.status(state.gate),
      worker: worker,
      reason: state.reason,
      observation: state.observation,
      observation_age_ms: age(state),
      restart_required: state.restart,
      execution_enabled: false
    }

    {:reply, result, state}
  end

  def handle_call({:dispatch, issue, host, run}, _from, state) do
    context = DeliveryGate.status(state.gate)

    with :ok <- ready(state, context),
         :ok <- Policy.admission(state.settings, context.state, state.observation, issue) do
      if context.state["cycle"] == nil do
        reserve(state, context, issue)
      else
        start_worker(state, context, issue, host, run)
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:check, handle, mode}, {pid, _}, state) do
    case state.worker do
      %{pid: ^pid, handle: ^handle, status: :running} = worker ->
        check_current_worker(state, worker, mode)

      _ ->
        {:reply, {:error, :worker_permit_revoked}, state}
    end
  end

  def handle_call({:pause, reason}, _from, state) do
    state = block(state, reason)
    {:reply, :ok, stop_worker(state, reason)}
  end

  def handle_call({:command, version, id, action, args}, _from, state) do
    context = DeliveryGate.status(state.gate)

    allowed =
      action in ~w(request_cancel resolve_interval confirm_ci_not_started extend_budget) or
        (state.worker == nil and ready(state, context) == :ok)

    result =
      if allowed,
        do: DeliveryGate.execute(state.gate, version, id, action, args),
        else: {:error, :reconciliation_required}

    state = if match?({:ok, _}, result), do: invalidate(state), else: state
    state = if action == "request_cancel" and match?({:ok, _}, result), do: stop_worker(state, :operator_cancel_pending), else: state
    {:reply, result, state}
  end

  def handle_call({:settings, config}, _from, state) do
    compatible = Config.delivery_observer_settings(config) == {:ok, state.settings}

    if compatible do
      {:reply, :ok, state}
    else
      state = %{stop_worker(block(state, "restart_required"), :restart_required) | restart: true}
      {:reply, {:error, :restart_required}, state}
    end
  end

  def handle_call({:cleanup, path}, _from, state) do
    context = DeliveryGate.status(state.gate)
    reply = with :ok <- ready(state, context), do: Policy.cleanup(context, path)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_read(state)}

  @impl true
  def handle_info(:observe, state), do: {:noreply, start_read(state)}

  def handle_info(:tick, state) do
    schedule_tick(state.opts)
    state = state |> check_deadline() |> account()
    {:noreply, maybe_read(state)}
  end

  def handle_info({ref, result}, %{read: %{task: %{ref: ref}} = read} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(read.timeout)
    state = %{state | read: nil}
    {:noreply, accept_read(state, read, result)}
  end

  def handle_info({:read_timeout, ref}, %{read: %{task: %{ref: ref}} = read} = state) do
    Task.shutdown(read.task, :brutal_kill)
    {:noreply, read_failed(%{state | read: nil}, :observation_deadline)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{read: %{task: %{ref: ref}}} = state),
    do: {:noreply, read_failed(%{state | read: nil}, :observation_failed)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: %{ref: ref}} = state),
    do: {:noreply, worker_down(state, reason)}

  def handle_info({:work_deadline, interval}, %{worker: %{interval: interval}} = state),
    do: {:noreply, stop_worker(block(state, "time_budget_exhausted"), :time_budget_exhausted)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.worker, do: Task.Supervisor.terminate_child(state.tasks, state.worker.pid)
    :ok
  end

  defp ready(state, context) do
    cond do
      state.restart -> {:error, :restart_required}
      state.worker != nil -> {:error, :worker_not_stopped}
      state.observation == nil or age(state) >= freshness(state) -> {:error, :observation_required}
      true -> Observation.validate(state.observation, state.settings, context)
    end
  end

  defp check_current_worker(state, worker, mode) do
    if not state.restart and state.now.() - worker.checked_at < freshness(state) and state.now.() < worker.deadline do
      worker = if mode == :effect, do: %{worker | effects: true}, else: worker
      {:reply, :ok, %{state | worker: worker}}
    else
      {:reply, {:error, :worker_permit_revoked}, stop_worker(state, :worker_permit_revoked)}
    end
  end

  defp reserve(state, context, issue) do
    cycle_id = id()
    args = %{"cycle_id" => cycle_id, "item_id" => issue.id, "issue_id" => issue.native_ref["issue_id"], "branch" => "agent/task-" <> cycle_id, "sha" => state.observation.facts["dev_sha"]}

    with :ok <- DeliveryGate.admission(state.gate, context.version, "new"),
         {:ok, _} <- DeliveryGate.execute(state.gate, context.version, "reserve-" <> cycle_id, "reserve", args) do
      {:reply, {:error, :reconciliation_required}, invalidate(state)}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp start_worker(state, context, issue, host, run) do
    runtime = self()

    timeout = Keyword.get(state.opts, :activation_timeout_ms, 30_000)

    case Task.Supervisor.start_child(state.tasks, fn -> inert_worker(runtime, run, timeout) end) do
      {:ok, pid} ->
        start_registered(state, context, issue, host, pid)

      {:error, _} ->
        {:reply, {:error, :spawn_failed}, state}
    end
  end

  defp start_registered(state, context, issue, host, pid) do
    interval = id()
    cycle = context.state["cycle"]
    budget = if cycle["budget"]["fixes"] == 0, do: "initial", else: "fix"

    case DeliveryGate.begin_work(state.gate, context.version, issue.id, interval, budget, pid) do
      {:ok, receipt} ->
        json =
          HookContext.build(state.settings, context, cycle, interval)
          |> Map.put("task_base_sha", cycle["work"]["base_sha"])
          |> Map.put("expected_dev_sha", state.observation.facts["dev_sha"])

        handle = %{runtime: self(), gate: state.gate, nonce: receipt.nonce, context: json}
        now = state.now.()

        worker = %{
          pid: pid,
          ref: Process.monitor(pid),
          item: issue.id,
          interval: interval,
          handle: handle,
          host: host,
          started_at: now,
          checked_at: now,
          elapsed_ms: 0,
          deadline: now + receipt.remaining_ms,
          status: :running,
          effects: false,
          watch_digest: state.observation.facts["watch_digest"]
        }

        send(pid, {:delivery_start, handle})
        Process.send_after(self(), {:work_deadline, interval}, receipt.remaining_ms)
        {:reply, {:ok, pid}, %{state | worker: worker, reason: nil, observation: nil}}

      {:error, _} = error ->
        Process.exit(pid, :kill)
        {:reply, error, invalidate(state)}
    end
  end

  defp inert_worker(runtime, run, timeout) do
    worker = self()
    spawn_link(fn -> guard_lifetime(runtime, worker) end)

    receive do
      {:delivery_start, handle} ->
        with :ok <- DeliveryGate.worker_check(handle.gate, handle.nonce, :activate),
             :ok <- check(handle) do
          run.(handle)
        end
    after
      timeout -> :ok
    end
  end

  defp guard_lifetime(runtime, worker) do
    controller_ref = Process.monitor(runtime)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^controller_ref, :process, ^runtime, _} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
    end
  end

  defp start_read(%{read: read} = state) when not is_nil(read), do: state
  defp start_read(%{restart: true} = state), do: state
  defp start_read(%{worker: %{status: status}} = state) when status != :running, do: state

  defp start_read(state) do
    if state.now.() < max(state.next_read_at, state.retry_at), do: state, else: launch_read(state)
  end

  defp launch_read(state) do
    context = DeliveryGate.status(state.gate)
    read_opts = Keyword.get(state.opts, :observer_options, [])

    {kind, fun, timeout} =
      if state.worker do
        watch = Keyword.get(state.opts, :watch, &Delivery.watch/4)
        {:watch, fn -> watch.(state.config, context, state.worker.watch_digest, read_opts) end, 30_000}
      else
        observer = Keyword.get(state.opts, :observer, &Delivery.observe/2)
        {:full, fn -> observer.(state.config, Keyword.put(read_opts, :context, context)) end, 300_000}
      end

    task = Task.Supervisor.async_nolink(state.tasks, fun)
    timer = Process.send_after(self(), {:read_timeout, task.ref}, timeout)
    read = %{task: task, timeout: timer, kind: kind, context: context, interval: if(state.worker, do: state.worker.interval), started_at: state.now.()}
    %{state | read: read, next_read_at: state.now.() + Keyword.get(state.opts, :poll_ms, 30_000)}
  end

  defp accept_read(state, %{kind: :watch, interval: interval, started_at: started}, :ok) do
    if state.worker && state.worker.interval == interval && state.worker.status == :running do
      %{state | worker: %{state.worker | checked_at: started}}
    else
      state
    end
  end

  defp accept_read(state, %{kind: :full, started_at: started}, {:ok, %Observation{} = observation}) do
    context = DeliveryGate.status(state.gate)

    with true <- state.now.() - started < freshness(state),
         :ok <- Observation.validate(observation, state.settings, context),
         {:ok, commands} <- Observation.commands(observation, state.settings, context) do
      state = %{state | observation: observation, observed_at: started, reason: observation.reasons}
      apply_observation(state, context, commands)
    else
      _ ->
        delay = max(observation.retry_after_seconds || 0, 30) * 1_000
        read_failed(%{state | next_read_at: state.now.() + delay}, :stale_or_incomplete_observation)
    end
  end

  defp accept_read(state, _, {:error, {:github_delivery_limited, seconds}}) do
    read_failed(%{state | next_read_at: state.now.() + seconds * 1_000}, :observation_rate_limited)
  end

  defp accept_read(state, _, _), do: read_failed(state, :observation_unavailable)

  defp apply_observation(state, context, commands) do
    command = Enum.find(commands, &Policy.new_command?(&1, context.state))
    sha = state.observation.facts["dev_sha"]
    result = DeliveryGate.reconcile(state.gate, context.version, state.settings.gate.scope, sha)

    if command && (result == :ok or command.action == "observe_ci") do
      case DeliveryGate.execute(state.gate, context.version, id(), command.action, command.args) do
        {:ok, _} -> invalidate(state)
        _ -> %{state | reason: :transition_rejected}
      end
    else
      state
    end
  end

  defp account(%{worker: %{status: :running} = worker} = state) do
    elapsed = max(worker.elapsed_ms, state.now.() - worker.started_at)
    args = %{"interval_id" => worker.interval, "elapsed_ms" => elapsed}

    case execute(state, "checkpoint", args) do
      {:ok, %{state: %{"cycle" => %{"phase" => "working"}}}} ->
        %{state | worker: %{worker | elapsed_ms: elapsed}}

      _ ->
        stop_worker(state, :worker_permission_or_budget_lost)
    end
  end

  defp account(state), do: state

  defp check_deadline(%{worker: %{status: :running} = worker} = state) do
    cond do
      state.now.() >= worker.deadline -> stop_worker(block(state, "time_budget_exhausted"), :time_budget_exhausted)
      state.now.() - worker.checked_at >= freshness(state) -> stop_worker(block(state, "observation_expired"), :observation_expired)
      true -> state
    end
  end

  defp check_deadline(state), do: state

  defp stop_worker(%{worker: %{status: :running} = worker} = state, reason) do
    Logger.warning("Delivery worker stop requested #{worker_context(worker)} reason=#{reason}")
    Process.exit(worker.pid, :kill)
    %{state | worker: %{worker | status: :stopping}, reason: reason, observation: nil}
  end

  defp stop_worker(state, reason), do: %{state | reason: reason, observation: nil}

  defp worker_down(state, reason) do
    worker = state.worker
    verifier = Keyword.get(state.opts, :stop_verifier, fn w -> if w.effects, do: :stop_unconfirmed, else: :stopped end)

    if verifier.(worker) == :stopped do
      elapsed = max(worker.elapsed_ms, state.now.() - worker.started_at)
      result = execute(state, "stop_work", %{"interval_id" => worker.interval, "elapsed_ms" => elapsed})
      state = %{state | worker: nil}
      state = if reason != :normal, do: block(state, "worker_stopped_requires_reconciliation"), else: state
      if match?({:ok, _}, result), do: invalidate(state), else: %{state | reason: :stop_accounting_unconfirmed}
    else
      state = block(state, "stop_unconfirmed")
      Logger.warning("Delivery worker stop unconfirmed #{worker_context(worker)}")
      %{state | worker: %{worker | status: :stop_unconfirmed}, reason: :stop_unconfirmed}
    end
  end

  defp block(state, reason) do
    context = DeliveryGate.status(state.gate)
    if context.state && context.state["cycle"], do: execute(state, "block", %{"reason" => to_string(reason)})
    %{state | observation: nil, reason: reason}
  end

  defp execute(state, action, args) do
    context = DeliveryGate.status(state.gate)
    DeliveryGate.execute(state.gate, context.version, id(), action, args)
  end

  defp invalidate(state) do
    send(self(), :observe)
    %{state | observation: nil, observed_at: nil, next_read_at: state.now.()}
  end

  defp read_failed(state, reason) do
    retry_at = max(state.retry_at, max(state.next_read_at, state.now.() + 30_000))
    stop_worker(%{state | observation: nil, retry_at: retry_at}, reason)
  end

  defp worker_context(worker) do
    identifier = "GHP-" <> Base.encode16(worker.item, case: :lower)
    "issue_id=#{worker.item} issue_identifier=#{identifier} interval_id=#{worker.interval}"
  end

  defp age(%{observed_at: nil}), do: nil
  defp age(state), do: state.now.() - state.observed_at
  defp freshness(state), do: Keyword.get(state.opts, :freshness_ms, 60_000)
  defp id, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  defp schedule_tick(opts), do: Process.send_after(self(), :tick, Keyword.get(opts, :checkpoint_ms, 10_000))

  defp maybe_read(state) do
    last = if state.worker, do: state.worker.checked_at, else: state.observed_at
    if is_nil(last) or state.now.() - last >= Keyword.get(state.opts, :poll_ms, 30_000), do: start_read(state), else: state
  end
end
