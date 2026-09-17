defmodule SymphonyElixir.Codex.ModelSelection do
  @moduledoc "Explicit isolated-worker model/effort pins, checked against app-server acknowledgements."
  alias SymphonyElixir.Runtime.Worker

  @spec load(map(), (map() -> {:ok, map()} | {:error, term()})) :: {:ok, map() | nil} | {:error, term()}
  def load(%{delivery: %{isolated: true} = handle}, rpc) do
    with {:ok, selection} <- Worker.model_selection(handle),
         {:ok, catalog} <- pages(rpc, nil, [], [], 20),
         :ok <- supported(selection, catalog) do
      {:ok, selection}
    else
      {:error, reason} when reason in [:selected_model_unavailable, :selected_effort_unavailable] ->
        Worker.model_rejected(handle, reason)

      _ ->
        Worker.model_rejected(handle, :model_catalog_unavailable)
    end
  end

  def load(_, _), do: {:ok, nil}

  @spec supported(map(), list()) :: :ok | {:error, atom()}
  def supported(%{"model" => model, "effort" => effort}, catalog) when is_binary(model) and is_binary(effort) and is_list(catalog) do
    case Enum.filter(catalog, &(is_map(&1) and &1["model"] == model and &1["hidden"] != true)) do
      [%{"supportedReasoningEfforts" => efforts}] when is_list(efforts) ->
        if Enum.any?(efforts, &(is_map(&1) and &1["reasoningEffort"] == effort)),
          do: :ok,
          else: {:error, :selected_effort_unavailable}

      _ ->
        {:error, :selected_model_unavailable}
    end
  end

  def supported(_, _), do: {:error, :model_selection_required}

  @spec thread_params(map() | nil) :: map()
  def thread_params(nil), do: %{}
  def thread_params(%{"model" => model, "effort" => effort}), do: %{"model" => model, "config" => %{"model_reasoning_effort" => effort}}

  @spec turn_params(map() | nil) :: map()
  def turn_params(nil), do: %{}
  def turn_params(%{"model" => model, "effort" => effort}), do: %{"model" => model, "effort" => effort}

  @spec accepted(map() | nil, map(), map()) :: :ok | {:error, term()}
  def accepted(nil, _, _), do: :ok

  def accepted(selection, %{delivery: handle}, response) do
    actual = %{"model" => response["model"], "effort" => response["reasoningEffort"]}

    if selection == actual,
      do: Worker.model_applied(handle, actual),
      else: Worker.model_rejected(handle, :model_application_mismatch)
  end

  defp pages(_, _, _, _, 0), do: {:error, :model_catalog_unavailable}

  defp pages(rpc, cursor, seen, models, remaining) do
    with {:ok, %{"data" => data} = result} <- rpc.(%{"limit" => 100, "includeHidden" => false, "cursor" => cursor}),
         true <- is_list(data) and length(data) <= 100 do
      next = result["nextCursor"]

      cond do
        next == nil ->
          {:ok, models ++ data}

        is_binary(next) and byte_size(next) <= 4096 and next not in seen ->
          pages(rpc, next, [next | seen], models ++ data, remaining - 1)

        true ->
          {:error, :model_catalog_unavailable}
      end
    else
      _ -> {:error, :model_catalog_unavailable}
    end
  end
end
