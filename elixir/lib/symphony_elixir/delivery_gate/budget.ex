defmodule SymphonyElixir.DeliveryGate.Budget do
  @moduledoc "Persistent reservations; elapsed time is supplied by the controller runtime."

  @defaults %{"initial_ms" => 3_600_000, "fix_ms" => 3_600_000, "fixes" => 2, "ci_attempts" => 6, "retries_per_sha" => 2}

  @spec new(map()) :: map()
  def new(limits \\ @defaults) do
    %{
      "limits" => Map.take(limits, Map.keys(@defaults)),
      "initial_ms" => 0,
      "fix_ms" => 0,
      "fixes" => 0,
      "fix_floor" => 0,
      "accounting_uncertain" => false,
      "interval" => nil,
      "interval_ids" => [],
      "ci" => %{},
      "ci_floor" => 0,
      "retry_floor" => %{},
      "external_ci" => %{},
      "extensions" => []
    }
  end

  @spec apply_command(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def apply_command(budget, "start_work", args) do
    key = args["budget"] <> "_ms"

    cond do
      budget["interval"] != nil ->
        {:error, :worker_not_stopped}

      args["interval_id"] in budget["interval_ids"] ->
        {:error, :interval_already_used}

      args["budget"] == "fix" and budget["fixes"] == 0 ->
        {:error, :fix_not_reserved}

      budget[key] >= budget["limits"][key] ->
        {:error, :time_budget_exhausted}

      true ->
        interval = %{"id" => args["interval_id"], "budget" => key, "elapsed_ms" => 0, "reserved_ms" => budget["limits"][key] - budget[key]}
        {:ok, Map.put(budget, "interval", interval)}
    end
  end

  def apply_command(budget, action, args) when action in ["checkpoint", "stop_work", "resolve_interval"] do
    case budget["interval"] do
      %{"id" => id, "elapsed_ms" => previous, "budget" => key} ->
        elapsed = interval_elapsed(budget, action, args["elapsed_ms"])

        if id == args["interval_id"] and elapsed >= previous do
          updated = Map.update!(budget, key, &(&1 + elapsed - previous))

          {:ok, finish_interval(updated, action, elapsed, id)}
        else
          {:error, :elapsed_time_regressed}
        end

      _ ->
        {:error, :unknown_interval}
    end
  end

  def apply_command(budget, "begin_fix", _) do
    cond do
      budget["interval"] != nil -> {:error, :worker_not_stopped}
      unresolved?(budget) -> {:error, :ci_unresolved}
      max(budget["fixes"], budget["fix_floor"]) >= budget["limits"]["fixes"] -> {:error, :fix_budget_exhausted}
      budget["fix_ms"] >= budget["limits"]["fix_ms"] -> {:error, :time_budget_exhausted}
      true -> {:ok, Map.put(budget, "fixes", max(budget["fixes"], budget["fix_floor"]) + 1)}
    end
  end

  def apply_command(budget, "reserve_ci", args) do
    entries = Map.values(budget["ci"])

    cond do
      budget["interval"] != nil ->
        {:error, :worker_not_stopped}

      Map.has_key?(budget["ci"], args["reservation_id"]) ->
        {:error, :reservation_already_used}

      unresolved?(budget) ->
        {:error, :ci_unresolved}

      max(length(entries), budget["ci_floor"]) >= budget["limits"]["ci_attempts"] ->
        {:error, :ci_budget_exhausted}

      true ->
        with :ok <- retry_allowed(budget, args) do
          sequence = max(length(entries), budget["ci_floor"]) + 1
          entry = Map.merge(args, %{"run_id" => nil, "run_attempt" => nil, "result" => "reserved", "sequence" => sequence})
          updated = put_in(budget, ["ci", args["reservation_id"]], entry)
          updated = account_retry(budget, updated, args)
          {:ok, %{updated | "ci_floor" => sequence}}
        end
    end
  end

  def apply_command(budget, "observe_ci", args) do
    id = args["reservation_id"]
    entry = budget["ci"][id]
    pair = {args["run_id"], args["run_attempt"]}

    cond do
      is_nil(entry) ->
        {:error, :unknown_reservation}

      Enum.any?(budget["ci"], fn {other, run} -> other != id and {run["run_id"], run["run_attempt"]} == pair end) ->
        {:error, :run_already_bound}

      entry["run_id"] != nil and {entry["run_id"], entry["run_attempt"]} != pair ->
        {:error, :reservation_run_changed}

      entry["result"] in ["success", "failure", "cancelled", "not_started"] and entry["result"] != args["result"] ->
        {:error, :ci_result_changed}

      true ->
        {:ok, put_in(budget, ["ci", id], Map.merge(entry, args))}
    end
  end

  def apply_command(budget, "external_ci", args) do
    key = "#{args["run_id"]}:#{args["run_attempt"]}"

    case budget["external_ci"][key] do
      nil -> {:ok, put_in(budget, ["external_ci", key], args)}
      ^args -> {:ok, budget}
      _ -> {:error, :external_run_changed}
    end
  end

  def apply_command(budget, "confirm_ci_not_started", args) do
    id = args["reservation_id"]

    case budget["ci"][id] do
      %{"run_id" => nil, "result" => result} when result in ["reserved", "unknown"] ->
        {:ok, put_in(budget, ["ci", id, "result"], "not_started")}

      _ ->
        {:error, :ci_absence_not_confirmable}
    end
  end

  def apply_command(budget, "extend_budget", args) do
    limits = Map.new(budget["limits"], fn {key, value} -> {key, value + args[key]} end)
    {:ok, %{budget | "limits" => limits, "extensions" => budget["extensions"] ++ [args]}}
  end

  @spec unresolved?(map()) :: boolean()
  def unresolved?(budget), do: Enum.any?(budget["ci"], fn {_, run} -> run["result"] in ["reserved", "pending", "unknown"] end)

  @spec stopped?(map()) :: boolean()
  def stopped?(budget), do: is_nil(budget["interval"])

  @spec exhausted?(map()) :: boolean()
  def exhausted?(budget) do
    case budget["interval"] do
      %{"budget" => key} -> budget[key] >= budget["limits"][key]
      nil -> false
    end
  end

  @spec latest_ci(map()) :: map() | nil
  def latest_ci(budget), do: budget["ci"] |> Map.values() |> Enum.max_by(& &1["sequence"], fn -> nil end)

  @spec work_available?(map()) :: boolean()
  def work_available?(budget) do
    key = if budget["fixes"] == 0, do: "initial_ms", else: "fix_ms"
    budget[key] < budget["limits"][key]
  end

  @spec mark_uncertain(map()) :: map()
  def mark_uncertain(budget) do
    retry_floor = Map.new(budget["ci"], fn {_, entry} -> {entry["sha"], budget["limits"]["retries_per_sha"]} end)

    %{
      budget
      | "initial_ms" => max(budget["initial_ms"], budget["limits"]["initial_ms"]),
        "fix_ms" => max(budget["fix_ms"], budget["limits"]["fix_ms"]),
        "fix_floor" => max(budget["fix_floor"], budget["limits"]["fixes"]),
        "accounting_uncertain" => true,
        "interval" => uncertain_interval(budget["interval"]),
        "ci_floor" => max(budget["ci_floor"], budget["limits"]["ci_attempts"]),
        "retry_floor" => retry_floor
    }
  end

  defp interval_elapsed(budget, "resolve_interval", elapsed), do: max(elapsed, budget["interval"]["reserved_ms"])
  defp interval_elapsed(_, _, elapsed), do: elapsed

  defp uncertain_interval(nil), do: nil
  defp uncertain_interval(interval), do: %{interval | "elapsed_ms" => max(interval["elapsed_ms"], interval["reserved_ms"])}

  defp account_retry(original, updated, %{"retry" => true, "sha" => sha}) do
    put_in(updated, ["retry_floor", sha], retry_count(original, sha) + 1)
  end

  defp account_retry(_, updated, _), do: updated

  defp retry_count(budget, sha) do
    count = Enum.count(budget["ci"], fn {_, run} -> run["sha"] == sha and run["retry"] end)
    max(count, Map.get(budget["retry_floor"], sha, 0))
  end

  defp finish_interval(budget, "checkpoint", elapsed, _id), do: put_in(budget, ["interval", "elapsed_ms"], elapsed)

  defp finish_interval(budget, "resolve_interval", elapsed, id) do
    budget |> finish_interval("stop_work", elapsed, id) |> Map.put("accounting_uncertain", true)
  end

  defp finish_interval(budget, _, _elapsed, id), do: %{budget | "interval" => nil, "interval_ids" => [id | budget["interval_ids"]]}

  defp retry_allowed(budget, args) do
    prior = budget["ci"] |> Map.values() |> Enum.filter(&(&1["sha"] == args["sha"]))
    count = retry_count(budget, args["sha"])

    cond do
      args["retry"] and prior == [] -> {:error, :retry_without_initial_run}
      not args["retry"] and prior != [] -> {:error, :same_sha_requires_retry}
      args["retry"] and count >= budget["limits"]["retries_per_sha"] -> {:error, :retry_budget_exhausted}
      true -> :ok
    end
  end
end
