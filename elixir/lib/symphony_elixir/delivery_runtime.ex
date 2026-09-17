defmodule SymphonyElixir.DeliveryRuntime do
  @moduledoc "Controller lifecycle coordinator with separately confirmed isolated resources."

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, DeliveryGate}
  alias SymphonyElixir.DeliveryGate.{Budget, Effects}
  alias SymphonyElixir.DeliveryRuntime.{HookContext, Policy}
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.{Observation, QueueConfirmation}
  alias SymphonyElixir.GitHubProjects.Publication
  alias SymphonyElixir.Operator.{Auth, Decision}
  alias SymphonyElixir.Operator.Policy, as: OperatorPolicy
  alias SymphonyElixir.Runtime.Worker

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

  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server), do: GenServer.call(server, :shutdown, 15_000)

  @spec tool(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def tool(handle, name, args) do
    with :ok <- check(handle, :effect), do: GenServer.call(handle.runtime, {:tool, handle, name, args}, 30_000)
  catch
    :exit, _ -> {:error, :delivery_runtime_unavailable}
  end

  @doc "Trusted controller only; operator authentication belongs to PR-10."
  @spec command(GenServer.server(), map(), String.t(), String.t(), map()) :: term()
  def command(server, version, id, action, args),
    do: GenServer.call(server, {:command, version, id, action, args}, 30_000)

  @spec check_settings(GenServer.server(), Config.Schema.t()) :: :ok | {:error, atom()}
  def check_settings(server, config), do: GenServer.call(server, {:settings, config}, 15_000)

  @spec cleanup(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def cleanup(server, path), do: GenServer.call(server, {:cleanup, path})

  @doc "Trusted controller boundary; never expose this context through HTTP."
  @spec operator_context(GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def operator_context(server), do: operator_call(server, :operator_context)

  @spec operator_apply(GenServer.server(), GenServer.server(), String.t(), String.t(), map(), term(), integer()) :: term()
  def operator_apply(server, auth, session, id, payload, observation, started),
    do: operator_call(server, {:operator_apply, auth, session, id, payload, observation, started})

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
        stopping: nil,
        effect: nil,
        effect_retry_at: now.(),
        read: nil,
        next_read_at: now.(),
        retry_at: now.(),
        reason: :reconciliation_required,
        restart: false,
        closing: false
      }

      send(self(), :observe)
      schedule_tick(opts)
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:operator_context, _, state) do
    context = DeliveryGate.status(state.gate)

    value = %{
      gate: context,
      config: state.config,
      settings: state.settings,
      observation: queue_readiness(state, context, state.observation),
      started_at: state.now.(),
      observe: Keyword.get(state.opts, :observer, &Delivery.observe/2),
      options: Keyword.put(Keyword.get(state.opts, :observer_options, []), :context, context)
    }

    {:reply, {:ok, value}, state}
  end

  def handle_call({:operator_apply, auth, session, id, payload, observation, started}, _, state) do
    result =
      with {:ok, actor} <- Auth.check(auth, session),
           {:ok, form} <- Auth.form(auth, session, id),
           true <- GenServer.whereis(form.runtime) == self(),
           true <- actor == form.actor,
           do: apply_operator(state, form, payload, observation, started),
           else: (
             false -> {:error, :operator_form_invalid}
             error -> error
           )

    next =
      case result do
        {:ok, %{replayed: false, kind: kind}} ->
          changed = invalidate(state)
          if Decision.restrictive?(kind), do: stop_worker(changed, :operator_decision), else: changed

        _ ->
          state
      end

    {:reply, result, next}
  end

  def handle_call(:status, _from, state) do
    worker = if state.worker, do: Map.take(state.worker, [:item, :interval, :status, :elapsed_ms, :effects]), else: nil
    context = DeliveryGate.status(state.gate)

    result = %{
      gate: context,
      worker: worker,
      reason: state.reason,
      observation: queue_readiness(state, context, state.observation),
      observation_age_ms: age(state),
      restart_required: state.restart,
      execution_enabled: Keyword.get(state.opts, :isolated, false),
      runtime_readiness: runtime_readiness(state),
      decisions: DeliveryGate.decisions(state.gate)
    }

    {:reply, result, state}
  end

  def handle_call({:dispatch, issue, host, run}, _from, state) do
    context = DeliveryGate.status(state.gate)

    with :ok <- ready(state, context),
         :ok <- runtime_admission(state, context),
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

  def handle_call({:tool, handle, name, args}, {pid, _}, %{worker: %{pid: pid, handle: handle, status: :running}} = state) do
    context = DeliveryGate.status(state.gate)

    case tool_command(state, context, name, args) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tool, _, _, _}, _, state), do: {:reply, {:error, :worker_permit_revoked}, state}

  def handle_call({:effect_send, id, step, proof}, {pid, _}, %{effect: %{task: %{pid: pid}, id: id}} = state) do
    cycle = DeliveryGate.status(state.gate).state["cycle"]

    result =
      with true <- cycle["cancellation"] == nil and not state.restart and not state.closing and effect_current?(state),
           :ok <- candidate_proof(state, id, step, proof),
           {:ok, _} <- execute(state, "effect_sent", %{"operation_id" => id, "step" => step}),
           do: :ok,
           else: (
             false -> {:error, :effect_revoked}
             error -> error
           )

    {:reply, result, state}
  end

  def handle_call({:effect_send, _, _, _}, _, state), do: {:reply, {:error, :effect_revoked}, state}

  def handle_call({:pause, reason}, _from, state) do
    state = block(state, reason)
    {:reply, :ok, stop_worker(state, reason)}
  end

  def handle_call(:shutdown, _from, state),
    do: {:reply, :ok, stop_worker(%{state | closing: true}, :controller_shutdown)}

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
    {:noreply, state |> maybe_read() |> pump_effect() |> notify_shutdown()}
  end

  def handle_info(:pump_effect, state), do: {:noreply, pump_effect(state)}

  def handle_info(:controller_shutdown, state),
    do: {:noreply, stop_worker(%{state | closing: true}, :controller_shutdown)}

  def handle_info(reason, state) when reason in [:runtime_activation_invalid, :runtime_worker_lost],
    do: {:noreply, stop_worker(block(state, Atom.to_string(reason)), reason)}

  def handle_info({:publication_stop, interval}, %{worker: %{interval: interval}} = state), do: {:noreply, stop_worker(state, :publication_requested)}

  def handle_info({ref, result}, %{stopping: %{task: %{ref: ref}} = stopping} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_stop(%{state | stopping: nil}, stopping.reason, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{stopping: %{task: %{ref: ref}}} = state),
    do: {:noreply, finish_stop(%{state | stopping: nil}, :stop_failed, :stop_unconfirmed)}

  def handle_info({ref, result}, %{effect: %{task: %{ref: ref}} = effect} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_effect(state, effect, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{effect: %{task: %{ref: ref}}} = state) do
    {:noreply, %{state | effect: nil, reason: :publication_result_unknown, effect_retry_at: state.now.() + 30_000}}
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
    if state.effect, do: Task.Supervisor.terminate_child(state.tasks, state.effect.task.pid)
    :ok
  end

  @impl true
  def format_status(_), do: %{state: :delivery_runtime_redacted}

  defp ready(state, context) do
    cond do
      state.closing -> {:error, :controller_shutdown}
      state.restart -> {:error, :restart_required}
      state.worker != nil or state.effect != nil -> {:error, :worker_not_stopped}
      state.observation == nil or age(state) >= freshness(state) -> {:error, :observation_required}
      true -> Observation.validate(state.observation, state.settings, context)
    end
  end

  defp apply_operator(state, form, payload, observation, started) do
    case DeliveryGate.decision(state.gate, form.id) do
      nil ->
        new_operator_decision(state, form, payload, observation, started)

      %{"args" => args} ->
        if args["request_hash"] == OperatorPolicy.hash(payload) and args["actor"] == form.actor and args["kind"] == form.action,
          do: {:ok, %{replayed: true, kind: form.action, id: form.id}},
          else: {:error, :command_id_reused}
    end
  end

  defp new_operator_decision(state, form, payload, observation, started) do
    context = DeliveryGate.status(state.gate)
    observation = queue_readiness(state, context, observation)

    with true <- context.version == form.version and state.settings.gate.scope == form.scope and not state.restart,
         :ok <- operator_observation(state, form, context, observation, started),
         {:ok, args} <- OperatorPolicy.build(form, payload, observation, state.settings, context.state),
         {:ok, _} <- DeliveryGate.execute(state.gate, context.version, form.id, "operator_decision", args) do
      {:ok, %{id: form.id, kind: form.action, replayed: false}}
    else
      false -> {:error, :operator_context_changed}
      error -> error
    end
  end

  defp queue_readiness(_, _, nil), do: nil

  defp queue_readiness(state, context, observation) do
    now = Keyword.get(state.opts, :wall_now, fn -> System.system_time(:millisecond) end).()
    observation = QueueConfirmation.apply(observation, context.state, now)
    %{observation | facts: Map.put(observation.facts, "controller_now_ms", now)}
  end

  defp operator_observation(state, form, context, observation, started) do
    if Decision.restrictive?(form.action) do
      :ok
    else
      with true <- state.worker == nil and state.effect == nil,
           true <- observation != nil and state.now.() - started < freshness(state),
           true <- form.stamp != nil and form.stamp == OperatorPolicy.stamp(observation),
           :ok <- Observation.validate(observation, state.settings, context),
           :ok <- DeliveryGate.reconcile(state.gate, context.version, state.settings.gate.scope, observation.facts["dev_sha"]),
           do: :ok,
           else: (
             false -> {:error, :operator_context_changed}
             error -> error
           )
    end
  end

  defp operator_call(server, request) do
    GenServer.call(server, request, 30_000)
  catch
    :exit, _ -> {:error, :delivery_runtime_unavailable}
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

        now = state.now.()
        handle = %{runtime: self(), gate: state.gate, nonce: receipt.nonce, context: json, isolated: Keyword.get(state.opts, :isolated, false), deadline: now + receipt.remaining_ms}

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
          row: Enum.find(state.observation.facts["project"]["items"], &(&1["item_id"] == issue.id)),
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
  defp start_read(%{effect: effect} = state) when not is_nil(effect), do: state
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
    observation = queue_readiness(state, context, observation)

    with true <- state.now.() - started < freshness(state),
         :ok <- Observation.validate(observation, state.settings, context),
         {:ok, commands} <- Observation.commands(observation, state.settings, context) do
      state = %{state | observation: observation, observed_at: started, reason: observation.reasons}
      state |> apply_observation(context, commands) |> pump_effect()
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

    if command && (result == :ok or command.action in ~w(observe_ci external_ci manual_ci)) do
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
    task = Task.Supervisor.async_nolink(state.tasks, fn -> verifier.(worker) end)
    %{state | stopping: %{task: task, reason: reason}, worker: %{worker | status: :stopping}}
  end

  defp finish_stop(state, reason, proof) do
    worker = state.worker

    if proof == :stopped do
      elapsed = max(worker.elapsed_ms, state.now.() - worker.started_at)
      result = execute(state, "stop_work", %{"interval_id" => worker.interval, "elapsed_ms" => elapsed})
      state = %{state | worker: nil}
      state = if reason != :normal and state.reason != :publication_requested, do: block(state, "worker_stopped_requires_reconciliation"), else: state
      if match?({:ok, _}, result), do: invalidate(state), else: %{state | reason: :stop_accounting_unconfirmed}
    else
      state = block(state, "stop_unconfirmed")
      Logger.warning("Delivery worker stop unconfirmed #{worker_context(worker)}")
      %{state | worker: %{worker | status: :stop_unconfirmed}, reason: :stop_unconfirmed}
    end
  end

  defp runtime_readiness(state) do
    if Keyword.get(state.opts, :isolated, false), do: Worker.status(), else: %{ready: false, reasons: [:execution_disabled]}
  end

  defp runtime_admission(state, context) do
    if Keyword.get(state.opts, :isolated, false) do
      cond do
        context.state["last_cycle"] != nil -> {:error, :pilot_finished}
        state.settings.project.item_ids == [] and context.state["cycle"] == nil -> {:error, :pilot_not_selected}
        runtime_readiness(state).ready != true -> {:error, :worker_not_ready}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp notify_shutdown(state) do
    if Keyword.get(state.opts, :isolated, false) and state.worker == nil and state.effect == nil and state.stopping == nil do
      last = DeliveryGate.status(state.gate).state["last_cycle"]

      if state.closing or last != nil do
        send(Worker, {:runtime_quiescent, last})
        %{state | closing: true}
      else
        state
      end
    else
      state
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

  defp tool_command(state, context, "project_context", args) when args == %{},
    do: {:ok, Map.take(context.state["cycle"], ~w(id phase task work budget block_reason)), state}

  defp tool_command(state, _context, "project_handoff", %{"operation_id" => id} = args) when map_size(args) == 1 do
    with {:ok, _} <- execute(state, "effect_submit", %{"operation_id" => id}) do
      Process.send_after(self(), {:publication_stop, state.worker.interval}, 50)
      {:ok, %{"operation_id" => id, "status" => "submitted"}, state}
    end
  end

  defp tool_command(state, _context, name, payload) do
    kind = %{"project_start" => "start", "project_report" => "report", "project_block" => "block", "project_prepare_pr" => "publish"}[name]

    if Effects.payload?(kind, payload) do
      id = :crypto.hash(:sha256, :erlang.term_to_binary({state.worker.interval, kind, payload}, [:deterministic])) |> Base.encode16(case: :lower)
      args = %{"operation_id" => id, "kind" => kind, "payload" => payload}

      with {:ok, _} <- execute(state, "effect_request", args) do
        schedule_block_stop(kind, state.worker.interval)
        send(self(), :pump_effect)
        {:ok, %{"operation_id" => id, "status" => if(kind == "publish", do: "prepared", else: "queued")}, state}
      end
    else
      {:error, :invalid_task_tool_arguments}
    end
  end

  defp schedule_block_stop("block", interval), do: Process.send_after(self(), {:publication_stop, interval}, 50)
  defp schedule_block_stop(_, _), do: :ok

  defp candidate_proof(state, id, "push", proof) do
    args = proof |> Map.take(~w(digest base_sha)) |> Map.put("operation_id", id)
    with {:ok, _} <- execute(state, "effect_candidate", args), do: :ok
  end

  defp candidate_proof(_, _, _, _), do: :ok

  defp pump_effect(%{effect: effect} = state) when not is_nil(effect), do: state
  defp pump_effect(%{restart: true} = state), do: state
  defp pump_effect(%{closing: true} = state), do: state

  defp pump_effect(state) do
    context = DeliveryGate.status(state.gate)
    cycle = context.state && context.state["cycle"]

    effect = next_effect(cycle)

    cond do
      effect == nil -> state
      effect_paused?(state, context, effect) -> state
      sent_effect?(effect) -> launch_effect(state, cycle, effect)
      effect["kind"] == "publish" -> pump_publication(state, context, cycle, effect)
      true -> launch_effect(state, cycle, effect)
    end
  end

  defp effect_paused?(state, context, effect) do
    context.mode not in [:reconciled, :needs_reconciliation] or state.now.() < state.effect_retry_at or
      (Decision.held?(context.state) and not sent_effect?(effect)) or
      worker_blocks_effect?(state.worker, effect) or (is_nil(state.worker) and state.observation == nil)
  end

  defp next_effect(nil), do: nil

  defp next_effect(cycle) do
    cycle |> Map.get("effects", %{}) |> Map.values() |> Enum.find(&select_effect?(&1, cycle))
  end

  defp select_effect?(effect, cycle) do
    active = not effect["cancelled"] and cycle["cancellation"] == nil and effect["submitted"]
    finishing = effect["kind"] == "publish" and cycle["phase"] == "awaiting_ci"
    sent_effect?(effect) or (active and (Effects.pending?(effect) or finishing))
  end

  defp sent_effect?(effect), do: get_in(effect, ["steps", Effects.next(effect), "status"]) == "sent"
  defp worker_blocks_effect?(nil, _), do: false
  defp worker_blocks_effect?(worker, effect), do: worker.status != :running or effect["kind"] in ~w(publish block)

  defp pump_publication(state, context, cycle, effect) do
    ci = Budget.latest_ci(cycle["budget"])

    if publication_base?(state, context, effect),
      do: advance_publication(state, cycle, effect, ci),
      else: %{state | reason: :publication_observation_required}
  end

  defp advance_publication(state, cycle, effect, ci) do
    cond do
      cycle["phase"] == "reserved" ->
        request = %{"reservation_id" => effect["operation_id"], "sha" => effect["payload"]["sha"], "retry" => false, "reason" => "Controller publication"}

        case execute(state, "reserve_ci", request) do
          {:ok, _} -> invalidate(state)
          _ -> %{state | reason: :publication_budget_required}
        end

      cycle["phase"] != "awaiting_ci" or not matching_ci?(ci, effect) ->
        state

      Effects.next(effect) in ~w(push pull) ->
        launch_effect(state, cycle, effect)

      ci["result"] == "success" ->
        launch_effect(state, cycle, effect)

      true ->
        %{state | reason: :awaiting_ci_or_manual_rerun}
    end
  end

  defp matching_ci?(ci, effect), do: ci["sha"] == effect["payload"]["sha"]

  defp publication_base?(state, context, effect) do
    observation = state.observation

    if current_observation?(state, context) do
      cycle = context.state["cycle"]
      base = if cycle["recovery"], do: cycle["work"]["base_sha"], else: context.state["baseline"]["sha"]
      permitted = ~w(manual_dev_validation_required task_pr_not_bound awaiting_review_or_merge pr_ci_missing pr_ci_pending pr_ci_failure)
      permitted = allow_effect_reason(permitted, effect, "pull", "sent", "pr_association_requires_operator")
      permitted = if get_in(effect, ["steps", "push", "status"]) == "confirmed", do: ["pr_head_changed" | permitted], else: permitted

      permitted =
        if cycle["recovery"],
          do: permitted ++ ~w(recovery_owner_retained deployment_failure deployment_cancelled deployment_timed_out deployment_startup_failure resume_queue_before_dev_validation),
          else: permitted

      observation.facts["dev_sha"] == base and Policy.check_base(cycle, context.state, observation) == :ok and
        Enum.all?(observation.reasons, &(&1 in permitted))
    else
      false
    end
  end

  defp current_observation?(state, context) do
    state.observation != nil and age(state) < freshness(state) and
      Observation.validate(state.observation, state.settings, context) == :ok
  end

  defp allow_effect_reason(reasons, effect, step, status, reason),
    do: if(get_in(effect, ["steps", step, "status"]) == status, do: [reason | reasons], else: reasons)

  defp launch_effect(state, cycle, effect) do
    state = cancel_read(state)
    runtime = self()
    options = Keyword.get(state.opts, :publication_options, [])
    base = if state.worker, do: state.worker.handle.context["expected_dev_sha"], else: state.observation.facts["dev_sha"]
    options = Keyword.put(options, :base_sha, base)
    authorize = fn step, proof -> GenServer.call(runtime, {:effect_send, effect["operation_id"], step, proof}, 15_000) end
    runner = Keyword.get(state.opts, :publication_step, &Publication.step/5)
    context = DeliveryGate.status(state.gate)

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        result = runner.(state.settings, cycle, effect, authorize, options)
        refresh_status_result(state, context, effect, result)
      end)

    %{state | effect: %{task: task, id: effect["operation_id"], cycle: cycle["id"], version: context.version, started_at: state.now.()}}
  end

  defp refresh_status_result(%{worker: worker} = state, context, %{"kind" => "start"}, {:ok, "status", result}) when not is_nil(worker) do
    watch = Keyword.get(state.opts, :watch_transition, &Delivery.watch_transition/5)

    with {:ok, proof} <- watch.(state.config, context, worker.watch_digest, worker.row, Keyword.get(state.opts, :observer_options, [])),
         do: {:ok, "status", Map.merge(result, proof)}
  end

  defp refresh_status_result(_, _, _, result), do: result

  defp finish_effect(state, record, {:ok, "finalize", result}) do
    context = DeliveryGate.status(state.gate)

    with true <- context.version == record.version and context.state["cycle"]["cancellation"] == nil and effect_current?(state),
         :ok <- DeliveryGate.reconcile(state.gate, context.version, state.settings.gate.scope, state.observation.facts["dev_sha"]),
         {:ok, _} <- execute(state, "handoff", Map.take(result, ~w(pr_number sha))) do
      invalidate(%{state | effect: nil})
    else
      _ -> invalidate(%{state | effect: nil, reason: :handoff_reconciliation_required})
    end
  end

  defp finish_effect(state, record, {:ok, step, result}) do
    context = DeliveryGate.status(state.gate)
    cycle = context.state["cycle"]
    effect = get_in(cycle, ["effects", record.id])
    args = %{"operation_id" => record.id, "step" => step}
    persisted_result = Map.drop(result, ~w(watch_digest row))
    # An existing remote postcondition can complete a not-yet-sent intent without a write.
    with true <- cycle["id"] == record.cycle and is_map(effect),
         :ok <- record_observed_effect(state, effect, args),
         {:ok, _} <- execute(state, "effect_confirm", Map.put(args, "result", persisted_result)),
         :ok <- finish_effect_transition(state, effect, step, result) do
      next = %{state | effect: nil}
      next = if step == "status" and state.worker, do: refresh_worker_status(next, result, record.started_at), else: next
      send(self(), :pump_effect)
      if next.worker, do: next, else: invalidate(next)
    else
      _ -> %{state | effect: nil, reason: :publication_reconciliation_required, effect_retry_at: state.now.() + 30_000}
    end
  end

  defp finish_effect(state, _, error) do
    seconds =
      case error do
        {:error, {:publication_limited, n}} -> n
        _ -> 30
      end

    %{state | effect: nil, reason: :publication_result_unknown, effect_retry_at: state.now.() + seconds * 1_000}
  end

  defp record_observed_effect(state, effect, args) do
    if effect["steps"][args["step"]] do
      :ok
    else
      with {:ok, _} <- execute(state, "effect_sent", args), do: :ok
    end
  end

  defp finish_effect_transition(state, _, "pull", result) do
    with {:ok, _} <- execute(state, "bind_pr", Map.take(result, ~w(pr_number sha))), do: :ok
  end

  defp finish_effect_transition(state, %{"kind" => "block"}, "status", _) do
    with {:ok, _} <- execute(state, "block", %{"reason" => "agent_requested_human_decision"}), do: :ok
  end

  defp finish_effect_transition(_, _, _, _), do: :ok

  defp refresh_worker_status(state, %{"watch_digest" => digest, "row" => row}, started),
    do: %{state | worker: %{state.worker | watch_digest: digest, row: row, checked_at: started}}

  defp refresh_worker_status(state, _, _), do: stop_worker(state, :project_status_requires_reconciliation)

  defp effect_current?(%{worker: worker} = state) when not is_nil(worker),
    do: not Decision.held?(DeliveryGate.status(state.gate).state) and worker.status == :running and state.now.() < worker.deadline and state.now.() - worker.checked_at < freshness(state)

  defp effect_current?(state), do: not Decision.held?(DeliveryGate.status(state.gate).state) and state.observation != nil and age(state) < freshness(state)

  defp cancel_read(%{read: nil} = state), do: state

  defp cancel_read(state) do
    Process.cancel_timer(state.read.timeout)
    Task.shutdown(state.read.task, :brutal_kill)
    %{state | read: nil}
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
