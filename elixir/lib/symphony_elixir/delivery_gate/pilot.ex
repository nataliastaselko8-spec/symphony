defmodule SymphonyElixir.DeliveryGate.Pilot do
  @moduledoc "Read-only evidence for selecting a different pilot; never migrates or repairs a journal."
  alias SymphonyElixir.DeliveryGate.{Snapshot, StatusSync}
  alias SymphonyElixir.Operator.Decision

  @spec inspect(map() | nil, map(), list()) :: {:ok, map()} | {:error, atom()}
  def inspect(snapshot, scope, items) do
    snapshot = if is_nil(snapshot), do: Snapshot.new(scope), else: snapshot

    with {:ok, verified} <- Snapshot.decode(snapshot, scope),
         state = verified["state"],
         :ok <- settled(state),
         {:ok, evidence} <- completion(state, items) do
      hash = :crypto.hash(:sha256, :erlang.term_to_binary(verified, [:deterministic])) |> Base.encode16(case: :lower)
      {:ok, Map.merge(evidence, %{"revision" => verified["revision"], "scope" => scope, "snapshot_sha256" => hash})}
    end
  end

  defp settled(state) do
    cond do
      state["status"] not in ~w(idle bootstrap_required) or state["cycle"] != nil -> {:error, :pilot_active_cycle}
      state["operator_pause"] != nil -> {:error, :pilot_operator_paused}
      state["environment_problem"] != nil -> {:error, :pilot_environment_problem}
      StatusSync.pending?(state) -> {:error, :pilot_status_sync_pending}
      true -> :ok
    end
  end

  defp completion(%{"last_cycle" => nil}, []), do: {:ok, %{"kind" => "initial", "status_sync" => "not_applicable"}}

  defp completion(%{"last_cycle" => %{"phase" => "completed", "recovery" => nil, "cancellation" => nil} = cycle} = state, [item]) do
    with true <- cycle["task"]["item_id"] == item and Decision.quiet?(cycle),
         {:ok, sync} <- final_status(state, cycle) do
      {:ok,
       %{
         "kind" => "completed",
         "cycle_id" => cycle["id"],
         "task" => cycle["task"],
         "work" => cycle["work"],
         "validation" => cycle["validation"],
         "completion" => cycle["completion"],
         "status_sync" => sync
       }}
    else
      _ -> {:error, :pilot_completion_unconfirmed}
    end
  end

  defp completion(_, _), do: {:error, :pilot_completion_required}

  defp final_status(state, cycle) do
    if Map.has_key?(state, "status_sync") do
      op = state |> StatusSync.operations() |> Enum.filter(&(&1["cycle_id"] == cycle["id"])) |> List.last()

      if op && op["role"] == "production_ready" && op["status"] == "confirmed" && op["evidence"] == StatusSync.evidence(cycle),
        do: {:ok, Map.take(op, ~w(id role status observed confirmed_at_ms))},
        else: {:error, :pilot_final_status_unconfirmed}
    else
      {:ok, "legacy_not_recorded"}
    end
  end
end
