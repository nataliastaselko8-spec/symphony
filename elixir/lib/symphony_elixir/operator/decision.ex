defmodule SymphonyElixir.Operator.Decision do
  @moduledoc "Closed durable operator decisions. Authentication and fresh evidence belong to the controller boundary."

  alias SymphonyElixir.DeliveryGate.{Budget, Command, Effects, State}

  @criteria ["app", "scenario", "services"]
  @restrictive ~w(pause problem cancel)
  @actions @restrictive ++ ~w(unpause validate recovery resume review_resume extend_budget finish_cancel)

  @spec actions() :: [String.t()]
  def actions, do: @actions

  @spec criteria() :: [String.t()]
  def criteria, do: @criteria

  @spec restrictive?(String.t()) :: boolean()
  def restrictive?(action), do: action in @restrictive

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(%{"kind" => kind, "actor" => actor, "reason" => reason, "request_hash" => hash, "data" => data} = args)
      when map_size(args) == 5 and is_map(data) do
    with true <- kind in @actions and is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
         :ok <- Command.validate("request_cancel", %{"actor" => actor, "reason" => reason}),
         :ok <- validate_data(kind, data, actor, reason) do
      :ok
    else
      _ -> {:error, :invalid_operator_decision}
    end
  end

  def validate(_), do: {:error, :invalid_operator_decision}

  @spec apply(map(), map()) :: {:ok, map()} | {:error, atom()}
  def apply(state, %{"kind" => kind} = args) do
    data = Map.merge(args["data"], Map.take(args, ~w(actor reason)))
    decide(state, kind, data)
  end

  @spec held?(map()) :: boolean()
  def held?(state), do: state["operator_pause"] != nil or (state["environment_problem"] != nil and is_nil(get_in(state, ["cycle", "recovery"])))

  @spec quiet?(map() | nil) :: boolean()
  def quiet?(nil), do: true
  def quiet?(cycle), do: stopped?(cycle) and not Effects.unresolved?(cycle)

  @spec stopped?(map() | nil) :: boolean()
  def stopped?(nil), do: true
  def stopped?(cycle), do: Budget.stopped?(cycle["budget"]) and not Budget.unresolved?(cycle["budget"])

  defp validate_data(kind, data, _, _) when kind in @restrictive or kind == "unpause",
    do: if(data == %{}, do: :ok, else: {:error, :invalid_operator_data})

  defp validate_data("validate", data, actor, reason) do
    if data["criteria"] == @criteria,
      do: Command.validate("bootstrap", Map.merge(data, %{"actor" => actor, "reason" => reason})),
      else: {:error, :criteria_required}
  end

  defp validate_data(kind, data, actor, reason) do
    command = if kind == "recovery", do: "assign_recovery", else: kind
    Command.validate(command, Map.merge(data, %{"actor" => actor, "reason" => reason}))
  end

  defp decide(state, "pause", args), do: {:ok, Map.put(state, "operator_pause", args)}
  defp decide(state, "unpause", _), do: {:ok, Map.put(state, "operator_pause", nil)}

  defp decide(state, "problem", args) do
    state = %{state | "environment_problem" => args, "baseline" => nil}

    if state["cycle"],
      do: State.apply_command(state, "block", %{"reason" => "operator_reported_problem"}),
      else: {:ok, state}
  end

  defp decide(state, "validate", args) do
    if quiet?(state["cycle"]), do: validate_state(state, args), else: {:error, :work_unresolved}
  end

  defp decide(state, "cancel", args), do: State.apply_command(state, "request_cancel", args)
  defp decide(state, "recovery", args), do: State.apply_command(state, "assign_recovery", args)
  defp decide(state, kind, args), do: State.apply_command(state, kind, args)

  defp validate_state(%{"cycle" => nil} = state, args),
    do: {:ok, %{state | "status" => "idle", "baseline" => args, "environment_problem" => nil}}

  defp validate_state(%{"cycle" => %{"work" => %{"merge_sha" => nil}} = cycle} = state, args) do
    if cycle["phase"] in ~w(needs_human_decision awaiting_review) and cycle["cancellation"] == nil,
      do: {:ok, %{state | "baseline" => args, "environment_problem" => nil}},
      else: {:error, :baseline_validation_not_allowed}
  end

  defp validate_state(state, args) do
    with {:ok, validated} <- State.apply_command(state, "validate_dev", Map.put(args, "passed", true)),
         {:ok, completed} <- finish(validated, args) do
      {:ok, Map.put(completed, "environment_problem", nil)}
    end
  end

  defp finish(%{"cycle" => cycle} = state, args) do
    cond do
      cycle["cancellation"] != nil -> State.apply_command(state, "finish_cancel", args)
      cycle["recovery"] != nil -> State.apply_command(state, "finish_recovery", Command.proof(args))
      true -> State.apply_command(state, "complete", Command.proof(args))
    end
  end
end
