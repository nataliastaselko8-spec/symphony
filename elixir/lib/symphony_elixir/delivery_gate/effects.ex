defmodule SymphonyElixir.DeliveryGate.Effects do
  @moduledoc "Durable outbox for a single task. Sent operations are reconciled, never blindly retried."
  alias SymphonyElixir.DeliveryGate.{Budget, Command}

  @steps %{"start" => ["status"], "report" => ["comment"], "block" => ["comment", "status"], "publish" => ["push", "pull", "comment", "link", "status"]}

  @spec validate(String.t(), map()) :: :ok | {:error, atom()}
  def validate("effect_request", args) when is_map(args) do
    if keys?(args, ~w(operation_id kind payload)) and text?(args["operation_id"], 100) and
         payload?(args["kind"], args["payload"]), do: :ok, else: {:error, :invalid_command_arguments}
  end

  def validate("effect_submit", args), do: fields(args, ~w(operation_id))

  def validate("effect_candidate", args) do
    if fields(args, ~w(operation_id digest base_sha)) == :ok and Regex.match?(~r/\A[0-9a-f]{64}\z/, args["digest"]) and
         Regex.match?(~r/\A[0-9a-f]{40}\z/, args["base_sha"]), do: :ok, else: {:error, :invalid_command_arguments}
  end

  def validate("effect_sent", args), do: fields(args, ~w(operation_id step))

  def validate("effect_confirm", args) when is_map(args) do
    if fields(Map.delete(args, "result"), ~w(operation_id step)) == :ok and is_map(args["result"]) and
         byte_size(Jason.encode!(args["result"])) <= 4096, do: :ok, else: {:error, :invalid_command_arguments}
  end

  def validate(_, _), do: {:error, :invalid_command_arguments}

  @spec payload?(term(), term()) :: boolean()
  def payload?("start", payload), do: payload == %{}
  def payload?(kind, payload) when kind in ["report", "block"], do: is_map(payload) and keys?(payload, ["body"]) and text?(payload["body"], 16_000)

  def payload?("publish", payload) do
    is_map(payload) and keys?(payload, ~w(sha title body)) and text?(payload["title"], 200) and
      text?(payload["body"], 16_000) and Command.validate("handoff", %{"sha" => payload["sha"], "pr_number" => 1}) == :ok
  end

  def payload?(_, _), do: false

  @spec apply_command(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def apply_command(cycle, "effect_request", args) do
    effects = Map.get(cycle, "effects", %{})
    existing = effects[args["operation_id"]]

    cond do
      existing && Map.take(existing, ~w(operation_id kind payload)) == args ->
        {:ok, cycle}

      existing != nil ->
        {:error, :effect_id_reused}

      cycle["phase"] != "working" or cycle["cancellation"] != nil ->
        {:error, :effect_not_allowed}

      Enum.any?(effects, fn {_, effect} -> pending?(effect) end) ->
        {:error, :effect_in_progress}

      true ->
        effect = Map.merge(args, %{"submitted" => args["kind"] != "publish", "steps" => %{}, "cancelled" => false})
        {:ok, Map.put(cycle, "effects", Map.put(effects, args["operation_id"], effect))}
    end
  end

  def apply_command(cycle, action, args) do
    effect = get_in(cycle, ["effects", args["operation_id"]])

    with true <- is_map(effect), {:ok, updated} <- change(cycle, effect, action, args) do
      {:ok, put_in(cycle, ["effects", args["operation_id"]], updated)}
    else
      false -> {:error, :unknown_effect}
      error -> error
    end
  end

  defp change(cycle, effect, "effect_submit", _) do
    if cycle["phase"] == "working" and cycle["cancellation"] == nil and effect["kind"] == "publish" and not effect["cancelled"],
      do: {:ok, Map.put(effect, "submitted", true)},
      else: {:error, :effect_not_allowed}
  end

  defp change(cycle, effect, "effect_candidate", args) do
    proof = Map.take(args, ~w(digest base_sha))

    if cycle["cancellation"] == nil and effect["kind"] == "publish" and effect["steps"]["push"] == nil and
         effect["candidate"] in [nil, proof], do: {:ok, Map.put(effect, "candidate", proof)}, else: {:error, :candidate_changed}
  end

  defp change(cycle, effect, "effect_sent", args) do
    step = args["step"]

    if cycle["cancellation"] == nil and not effect["cancelled"] and effect["submitted"] and next(effect) == step and
         effect["steps"][step] == nil and allowed_step?(cycle, effect, step) do
      {:ok, put_in(effect, ["steps", step], %{"status" => "sent"})}
    else
      {:error, :effect_send_not_allowed}
    end
  end

  defp change(_, effect, "effect_confirm", args) do
    step = args["step"]
    result = %{"status" => "confirmed", "result" => args["result"]}

    case effect["steps"][step] do
      %{"status" => "sent"} -> {:ok, put_in(effect, ["steps", step], result)}
      ^result -> {:ok, effect}
      _ -> {:error, :effect_confirmation_not_allowed}
    end
  end

  defp allowed_step?(cycle, %{"kind" => "publish"} = effect, step) do
    ci = Budget.latest_ci(cycle["budget"])

    Budget.stopped?(cycle["budget"]) and cycle["phase"] == "awaiting_ci" and is_map(ci) and
      ci["sha"] == effect["payload"]["sha"] and
      (step in ["push", "pull"] or ci["result"] == "success")
  end

  defp allowed_step?(cycle, _, _), do: cycle["phase"] in ~w(working reserved needs_human_decision)

  @spec next(map()) :: String.t() | nil
  def next(effect), do: Enum.find(@steps[effect["kind"]], &(get_in(effect, ["steps", &1, "status"]) != "confirmed"))

  @spec pending?(map()) :: boolean()
  def pending?(effect), do: not effect["cancelled"] and next(effect) != nil

  @spec unresolved?(map()) :: boolean()
  def unresolved?(cycle) do
    Enum.any?(Map.get(cycle, "effects", %{}), fn {_, effect} ->
      pending?(effect) or Enum.any?(effect["steps"], fn {_, step} -> step["status"] == "sent" end)
    end)
  end

  @spec cancel(map()) :: map()
  def cancel(cycle), do: Map.put(cycle, "effects", Map.new(Map.get(cycle, "effects", %{}), fn {id, effect} -> {id, Map.put(effect, "cancelled", true)} end))

  @spec finish_attempt(map()) :: map()
  def finish_attempt(cycle), do: cancel(cycle)

  @spec sent?(map()) :: boolean()
  def sent?(cycle), do: Enum.any?(Map.get(cycle, "effects", %{}), fn {_, effect} -> Enum.any?(effect["steps"], fn {_, step} -> step["status"] == "sent" end) end)

  defp fields(args, keys) do
    if is_map(args) and keys?(args, keys) and Enum.all?(keys, &text?(args[&1], 100)), do: :ok, else: {:error, :invalid_command_arguments}
  end

  defp keys?(args, keys), do: Enum.sort(Map.keys(args)) == Enum.sort(keys)
  defp text?(value, limit), do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit and String.trim(value) != "" and not String.contains?(value, <<0>>)
end
