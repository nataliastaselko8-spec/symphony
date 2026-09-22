defmodule SymphonyElixir.DeliveryGate do
  alias SymphonyElixir.Operator.Decision

  @moduledoc """
  Single writer for the durable repository cycle. Internal controller API only.

  This foundation does not start a scheduler, authenticate an operator, classify
  CI failures, or make network requests. PR-07/08/10 must supply verified facts,
  actual worker lifecycle, and authenticated decisions. Loading a snapshot never
  grants admission. Receipts, especially replayed receipts, are not spawn tokens.
  """

  use GenServer

  alias SymphonyElixir.DeliveryGate.{Budget, Settings, Snapshot, State, Store}

  @recovery_commands ~w(checkpoint stop_work resolve_interval observe_ci external_ci block request_cancel confirm_ci_not_started effect_request effect_submit effect_sent effect_confirm effect_candidate bind_pr manual_ci status_result)
  @storage_errors [:store_changed, :store_unavailable, :store_operation_failed, :store_timeout]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @doc "Controller-only bounded decision history and idempotency lookup."
  @spec decisions(GenServer.server()) :: [map()]
  def decisions(server), do: GenServer.call(server, :decisions)

  @spec decision(GenServer.server(), String.t()) :: map() | nil
  def decision(server, id), do: GenServer.call(server, {:decision, id})

  @spec execute(GenServer.server(), map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def execute(server, version, id, action, args), do: GenServer.call(server, {:execute, version, id, action, args}, 15_000)

  @spec reconcile(GenServer.server(), map(), map(), String.t()) :: :ok | {:error, atom()}
  def reconcile(server, version, scope, dev_sha), do: GenServer.call(server, {:reconcile, version, scope, dev_sha})

  @spec admission(GenServer.server(), map(), String.t()) :: :ok | {:error, atom()}
  def admission(server, version, item), do: GenServer.call(server, {:admission, version, item})

  @doc "Commit an interval before granting one registered, inert worker permission to activate."
  @spec begin_work(GenServer.server(), map(), String.t(), String.t(), String.t(), pid(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def begin_work(server, version, item, interval, budget, pid, sync \\ nil),
    do: GenServer.call(server, {:begin_work, version, item, interval, budget, pid, sync}, 15_000)

  @spec worker_check(GenServer.server(), reference(), :activate | :continue) :: :ok | {:error, atom()}
  def worker_check(server, nonce, mode), do: GenServer.call(server, {:worker_check, nonce, mode})

  @spec restore_backup(GenServer.server(), map(), String.t(), String.t()) :: :ok | {:error, atom()}
  def restore_backup(server, version, actor, reason), do: GenServer.call(server, {:restore, version, actor, reason}, 15_000)

  @spec check_settings(GenServer.server(), map()) :: :ok | {:error, :restart_required}
  def check_settings(server, settings), do: GenServer.call(server, {:settings, settings})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    settings = Keyword.fetch!(opts, :settings)

    case Store.open(settings.path) do
      {:ok, port} ->
        {snapshot, mode} = load(port, settings.scope)
        state = %{port: port, settings: settings, snapshot: snapshot, mode: mode, epoch: epoch()}
        {:ok, Map.merge(state, %{verified_sha: nil, permit: nil})}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:decisions, _from, state), do: {:reply, Enum.take(decisions_list(state), -50), state}
  def handle_call({:decision, id}, _from, state), do: {:reply, Enum.find(decisions_list(state), &(&1["id"] == id)), state}

  def handle_call({:settings, proposed}, _from, state) do
    reply = if Settings.compatible?(state.settings, proposed), do: :ok, else: {:error, :restart_required}
    {:reply, reply, state}
  end

  def handle_call({:admission, version, item}, _from, state) do
    reply = check_admission(state, version, item)

    next = if storage_error?(reply), do: unavailable(state), else: state
    {:reply, reply, next}
  end

  def handle_call({:begin_work, version, item, interval, budget, pid, sync}, _from, state) do
    args = %{"interval_id" => interval, "budget" => budget}
    {action, args} = if sync, do: {"lifecycle", Map.merge(sync, %{"action" => "start_work", "args" => args})}, else: {"start_work", args}

    with true <- is_binary(interval) and is_pid(pid) and node(pid) == node() and Process.alive?(pid),
         :ok <- check_admission(state, version, item),
         {:ok, candidate, :new} <-
           Snapshot.append(state.snapshot, "work-" <> interval, version.revision, action, args, System.system_time(:millisecond)),
         :ok <- command_allowed(state, action, args, :new),
         true <- candidate["state"]["cycle"]["phase"] == "working" do
      case persist_command(state, candidate, :new) do
        {:reply, {:ok, receipt}, next} ->
          remaining = candidate["state"]["cycle"]["budget"]["interval"]["reserved_ms"]
          nonce = make_ref()
          deadline = System.monotonic_time(:millisecond) + remaining
          permit = %{nonce: nonce, pid: pid, interval: interval, activated: false, deadline: deadline}
          {:reply, {:ok, Map.merge(receipt, %{nonce: nonce, remaining_ms: remaining})}, %{next | permit: permit}}

        failure ->
          failure
      end
    else
      {:error, reason} ->
        next = if storage_error?({:error, reason}), do: unavailable(state), else: state
        {:reply, {:error, reason}, next}

      _ ->
        {:reply, {:error, :work_start_rejected}, state}
    end
  end

  def handle_call({:worker_check, nonce, mode}, {pid, _}, state) do
    reply = check_worker(state, nonce, pid, mode)
    next = if reply == :ok, do: put_in(state, [:permit, :activated], true), else: state
    {:reply, reply, if(storage_error?(reply), do: unavailable(next), else: next)}
  end

  def handle_call({:reconcile, version, scope, sha}, _from, state) do
    reply =
      with :ok <- current_version(state, version),
           true <- state.mode not in [:recovery_required, :store_unavailable],
           true <- scope == state.settings.scope and is_binary(sha) and Regex.match?(~r/^[0-9a-f]{40}$/, sha),
           true <- quiescent?(state.snapshot) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :reconciliation_incomplete}
      end

    if reply == :ok do
      {:reply, :ok, %{state | mode: :reconciled, verified_sha: sha}}
    else
      {:reply, reply, %{state | verified_sha: nil}}
    end
  end

  def handle_call({:execute, version, id, action, args}, _from, state) do
    with :ok <- same_epoch(state, version),
         true <- state.snapshot != nil,
         {:ok, candidate, result} <- Snapshot.append(state.snapshot, id, version[:revision], action, args, System.system_time(:millisecond)),
         :ok <- command_allowed(state, action, args, result) do
      persist_command(state, candidate, result)
    else
      false -> {:reply, {:error, :recovery_required}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:restore, version, actor, reason}, _from, state) do
    with :ok <- current_version(state, version),
         true <- state.mode == :recovery_required,
         {:ok, backup} <- Store.request(state.port, %{"op" => "backup"}),
         {:ok, decoded} <- Snapshot.decode(backup, state.settings.scope),
         {:ok, recorded, :new} <- Snapshot.append(decoded, "restore-" <> epoch(), decoded["revision"], "record_restore", %{"actor" => actor, "reason" => reason}, System.system_time(:millisecond)),
         {:ok, true} <- Store.request(state.port, %{"op" => "restore", "snapshot" => recorded}) do
      {:reply, :ok, %{state | snapshot: recorded, epoch: epoch(), mode: :needs_reconciliation, verified_sha: nil}}
    else
      _ -> {:reply, {:error, :restore_failed}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:noreply, unavailable(state)}
  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, unavailable(state)}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Store.close(state.port)

  defp persist_command(state, _candidate, :replayed) do
    {:reply, {:ok, %{version: version(state), replayed: true, state: state.snapshot["state"]}}, state}
  end

  defp persist_command(state, candidate, :new) do
    case Store.request(state.port, %{"op" => "write", "snapshot" => candidate}) do
      {:ok, true} ->
        next = %{state | snapshot: candidate, verified_sha: nil, mode: :needs_reconciliation}
        {:reply, {:ok, %{version: version(next), replayed: false, state: candidate["state"]}}, next}

      {:error, _} = error ->
        {:reply, error, unavailable(state)}
    end
  end

  defp command_allowed(%{mode: mode}, _, _, _) when mode in [:store_unavailable, :recovery_required], do: {:error, mode}
  defp command_allowed(_, _, _, :replayed), do: :ok

  defp command_allowed(state, action, args, result) when action in ~w(status_transition lifecycle) do
    if String.downcase(args["repo"]) == String.downcase(state.settings.scope["repo"]), do: command_allowed(state, args["action"], args["args"], result), else: {:error, :status_scope_changed}
  end

  defp command_allowed(state, "operator_decision", args, _) do
    if Decision.restrictive?(args["kind"]) do
      :ok
    else
      verified_operator(state, args["data"]["sha"])
    end
  end

  defp command_allowed(_, action, _, _) when action in @recovery_commands, do: :ok

  defp command_allowed(state, action, args, _) do
    with :ok <- reconciled(state),
         :ok <- if(action == "start_work", do: validated_base(state), else: :ok) do
      if action in ~w(bootstrap reserve merged deployment validate_dev complete finish_cancel assign_recovery finish_recovery resume resume_delivery review_resume) and
           args["sha"] != state.verified_sha do
        {:error, :observation_sha_changed}
      else
        :ok
      end
    end
  end

  defp verified_operator(state, sha) do
    with :ok <- reconciled(state) do
      if sha in [nil, state.verified_sha], do: :ok, else: {:error, :observation_sha_changed}
    end
  end

  defp load(port, scope) do
    case Store.request(port, %{"op" => "read"}) do
      {:ok, nil} ->
        {Snapshot.new(scope), :bootstrap_required}

      {:ok, snapshot} ->
        case Snapshot.decode(snapshot, scope) do
          {:ok, decoded} -> {decoded, :needs_reconciliation}
          {:error, _} -> {nil, :recovery_required}
        end

      {:error, _} ->
        {nil, :recovery_required}
    end
  end

  defp current_version(state, proposed) do
    if proposed == version(state), do: :ok, else: {:error, :stale_version}
  end

  defp check_admission(state, version, item) do
    with :ok <- current_version(state, version),
         :ok <- reconciled(state),
         :ok <- validated_base(state),
         :ok <- no_live_permit(state.permit),
         :ok <- store_matches(state) do
      State.admission(state.snapshot["state"], item)
    end
  end

  defp no_live_permit(nil), do: :ok
  defp no_live_permit(%{pid: pid}), do: if(Process.alive?(pid), do: {:error, :worker_still_alive}, else: :ok)

  defp store_matches(state) do
    case Store.request(state.port, %{"op" => "read"}) do
      {:ok, persisted} when persisted == state.snapshot -> :ok
      {:ok, _} -> {:error, :store_changed}
      {:error, _} = error -> error
    end
  end

  defp check_worker(%{permit: %{nonce: nonce, pid: pid} = permit} = state, nonce, pid, mode) do
    cycle = state.snapshot["state"]["cycle"]
    valid_mode = valid_permit_mode?(mode, permit.activated)

    allowed =
      state.mode not in [:store_unavailable, :recovery_required] and valid_mode and not Decision.held?(state.snapshot["state"]) and
        cycle["phase"] == "working" and cycle["cancellation"] == nil and
        get_in(cycle, ["budget", "interval", "id"]) == permit.interval and
        System.monotonic_time(:millisecond) < permit.deadline

    if allowed, do: store_matches(state), else: {:error, :worker_permit_revoked}
  end

  defp check_worker(_, _, _, _), do: {:error, :worker_permit_revoked}

  defp valid_permit_mode?(:activate, activated), do: not activated
  defp valid_permit_mode?(:continue, activated), do: activated
  defp valid_permit_mode?(_, _), do: false

  defp same_epoch(state, %{epoch: epoch}) when epoch == state.epoch, do: :ok
  defp same_epoch(_, _), do: {:error, :stale_version}

  defp reconciled(%{mode: :reconciled, verified_sha: sha}) when is_binary(sha), do: :ok
  defp reconciled(_), do: {:error, :reconciliation_required}

  defp validated_base(state) do
    cycle = state.snapshot["state"]["cycle"]
    proof = if is_map(cycle) and cycle["recovery"] != nil, do: %{"sha" => cycle["work"]["base_sha"]}, else: state.snapshot["state"]["baseline"]

    case proof do
      %{"sha" => sha} when sha == state.verified_sha -> :ok
      _ -> {:error, :unvalidated_base}
    end
  end

  defp quiescent?(%{"state" => %{"cycle" => nil}}), do: true
  defp quiescent?(%{"state" => %{"cycle" => cycle}}), do: Budget.stopped?(cycle["budget"]) and not Budget.unresolved?(cycle["budget"])

  defp version(state), do: %{epoch: state.epoch, revision: if(state.snapshot, do: state.snapshot["revision"], else: nil)}
  defp epoch, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp unavailable(state), do: %{state | mode: :store_unavailable, verified_sha: nil, permit: nil}
  defp storage_error?({:error, reason}), do: reason in @storage_errors
  defp storage_error?(_), do: false

  defp public_status(state) do
    %{version: version(state), mode: state.mode, state: if(state.snapshot, do: state.snapshot["state"], else: nil)}
  end

  defp decisions_list(%{snapshot: nil}), do: []

  defp decisions_list(state) do
    state.snapshot["commands"]
    |> Enum.map(fn
      %{"action" => "lifecycle", "args" => %{"action" => "operator_decision", "args" => args}} = entry -> %{entry | "action" => "operator_decision", "args" => args}
      entry -> entry
    end)
    |> Enum.filter(&(&1["action"] == "operator_decision"))
  end
end
