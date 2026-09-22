defmodule SymphonyElixir.DeliveryGate.StatusSync do
  @moduledoc "Journal-backed controller status intents. Legacy snapshots remain unchanged until an explicit transition."

  alias SymphonyElixir.DeliveryGate.{Command, State}

  @actions ~w(start_work block handoff merged complete resume review_resume review_started)
  @outcomes ~w(sent confirmed retry unknown conflict failed superseded)
  @terminal ~w(confirmed superseded)

  @spec validate(String.t(), term()) :: :ok | {:error, atom()}
  def validate("status_transition", args) when is_map(args) do
    valid =
      keys?(args, ~w(action args from reason repo)) and args["action"] in @actions and
        is_map(args["args"]) and text?(args["from"]) and text?(args["reason"]) and
        is_binary(args["repo"]) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, args["repo"])

    if valid, do: validate_action(args["action"], args["args"]), else: {:error, :invalid_status_transition}
  end

  def validate("status_result", args) when is_map(args) do
    valid =
      keys?(args, ~w(operation_id outcome observed error at_ms retry_at_ms)) and text?(args["operation_id"]) and
        args["outcome"] in @outcomes and nullable_text?(args["observed"]) and nullable_text?(args["error"]) and
        natural?(args["at_ms"]) and natural?(args["retry_at_ms"])

    if valid, do: :ok, else: {:error, :invalid_status_result}
  end

  def validate(_, _), do: {:error, :invalid_status_command}

  @spec transition(map(), map()) :: {:ok, map()} | {:error, atom()}
  def transition(state, command) do
    args = command["args"]

    with :ok <- validate("status_transition", args),
         true <- length(operations(state)) < 256,
         {:ok, next} <- apply_action(state, args["action"], args["args"]),
         cycle when is_map(cycle) <- next["cycle"] || next["last_cycle"],
         role when is_binary(role) <- role(args["action"], cycle) do
      record(next, command, cycle, role)
    else
      {:error, _} = error -> error
      _ -> {:error, :status_transition_not_allowed}
    end
  end

  @spec record(map(), map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def record(state, command, cycle, role) do
    args = command["args"]

    if length(operations(state)) < 256 do
      operation = %{
        "id" => command["id"],
        "sequence" => command["expected_revision"] + 1,
        "created_at_ms" => command["at_ms"],
        "event" => args["action"],
        "reason" => args["reason"],
        "repo" => args["repo"],
        "cycle_id" => cycle["id"],
        "task" => cycle["task"],
        "evidence" => evidence(cycle),
        "from" => args["from"],
        "role" => role,
        "status" => "pending",
        "observed" => nil,
        "error" => nil,
        "sent" => false,
        "attempts" => 0,
        "checks" => 0,
        "retry_at_ms" => 0,
        "confirmed_at_ms" => nil
      }

      {:ok, Map.put(state, "status_sync", operations(state) ++ [operation])}
    else
      {:error, :status_transition_not_allowed}
    end
  end

  @spec result(map(), map()) :: {:ok, map()} | {:error, atom()}
  def result(state, args) do
    with :ok <- validate("status_result", args),
         op when is_map(op) <- Enum.find(operations(state), &(&1["id"] == args["operation_id"])),
         true <- op["status"] not in @terminal,
         true <- args["outcome"] != "sent" or (not op["sent"] and current?(state, op)) do
      next = Map.merge(op, %{"status" => args["outcome"], "observed" => args["observed"], "error" => args["error"], "retry_at_ms" => args["retry_at_ms"]})
      next = if args["outcome"] == "sent", do: %{next | "sent" => true, "attempts" => op["attempts"] + 1}, else: next
      next = if args["outcome"] == "sent", do: next, else: %{next | "checks" => op["checks"] + 1}
      next = if args["outcome"] == "retry", do: %{next | "sent" => false}, else: next
      next = if args["outcome"] == "confirmed", do: %{next | "confirmed_at_ms" => args["at_ms"]}, else: next
      {:ok, Map.put(state, "status_sync", Enum.map(operations(state), fn old -> if old["id"] == op["id"], do: next, else: old end))}
    else
      {:error, _} = error -> error
      _ -> {:error, :status_result_not_allowed}
    end
  end

  @spec operations(map() | nil) :: [map()]
  def operations(state), do: if(is_map(state), do: Map.get(state, "status_sync", []), else: [])

  @spec pending?(map() | nil) :: boolean()
  def pending?(state), do: Enum.any?(operations(state), &(&1["status"] not in @terminal))

  @spec next(map(), integer()) :: map() | nil
  def next(state, now) do
    op = Enum.find(operations(state), &(&1["status"] not in @terminal))
    if op && (op["status"] not in ~w(conflict failed) or (not op["sent"] and not current?(state, op))) && op["retry_at_ms"] <= now, do: op
  end

  @spec recheck(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def recheck(state, id) do
    case Enum.find(operations(state), &(&1["id"] == id and &1["status"] not in @terminal)) do
      nil ->
        {:error, :status_result_not_allowed}

      op ->
        sent = op["sent"] and op["error"] not in ~w(status_permission_denied status_write_refused)
        next = %{op | "status" => if(sent, do: "unknown", else: "pending"), "sent" => sent, "checks" => 0, "attempts" => 0, "retry_at_ms" => 0}
        {:ok, Map.put(state, "status_sync", Enum.map(operations(state), fn old -> if old["id"] == id, do: next, else: old end))}
    end
  end

  @spec current?(map(), map()) :: boolean()
  def current?(state, op) do
    cycle = cycle(state, op)

    is_map(cycle) and evidence(cycle) == op["evidence"] and
      not Enum.any?(operations(state), &(&1["sequence"] > op["sequence"] and &1["task"] == op["task"]))
  end

  @spec cycle(map(), map()) :: map() | nil
  def cycle(state, op), do: Enum.find([state["cycle"], state["last_cycle"]], &(is_map(&1) and &1["id"] == op["cycle_id"] and &1["task"] == op["task"]))

  @spec view(map() | nil, map()) :: [map()]
  def view(state, roles) do
    Enum.map(operations(state), fn op ->
      op
      |> Map.take(~w(id sequence role status observed error created_at_ms confirmed_at_ms retry_at_ms attempts checks))
      |> Map.put("target", roles[op["role"]])
    end)
  end

  defp apply_action(%{"cycle" => %{"phase" => "awaiting_review"}} = state, "review_started", %{}), do: {:ok, state}
  defp apply_action(_, "review_started", _), do: {:error, :review_not_ready}
  defp apply_action(state, action, args), do: State.apply_command(state, action, args)
  defp validate_action("review_started", args), do: if(args == %{}, do: :ok, else: {:error, :invalid_status_transition})
  defp validate_action(action, args), do: Command.validate(action, args)
  defp role("block", %{"phase" => "needs_human_decision"}), do: "blocked"
  defp role("handoff", %{"phase" => "awaiting_review"}), do: "handoff"
  defp role("review_started", %{"phase" => "awaiting_review"}), do: "review"
  defp role("merged", %{"phase" => "awaiting_deployment"}), do: "dev_validation"
  defp role("complete", %{"phase" => "completed"}), do: "production_ready"
  defp role(action, %{"phase" => phase}) when action in ~w(start_work resume review_resume) and phase in ~w(working reserved), do: "working"
  defp role(_, _), do: nil
  @spec evidence(map()) :: map()
  def evidence(cycle), do: Map.take(cycle, ~w(phase task work deployment validation cancellation))
  defp keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp text?(value), do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..2048 and String.trim(value) != ""
  defp nullable_text?(value), do: is_nil(value) or text?(value)
  defp natural?(value), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
end
