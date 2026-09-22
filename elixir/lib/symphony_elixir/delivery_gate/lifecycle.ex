defmodule SymphonyElixir.DeliveryGate.Lifecycle do
  @moduledoc "Atomic controller events and their board intent; legacy commands retain their replay semantics."
  alias SymphonyElixir.DeliveryGate.{Command, State, StatusSync}

  @actions ~w(start_work checkpoint stop_work resolve_interval reserve_ci observe_ci external_ci begin_fix extend_budget
    confirm_ci_not_started manual_ci bind_pr handoff merged deployment validate_dev complete block request_cancel
    resume review_resume operator_decision effect_request effect_submit effect_sent effect_confirm effect_candidate)

  @spec enabled?(map()) :: boolean()
  def enabled?(settings), do: is_binary(settings.project.states["production_ready"])

  @spec wrap(map(), map(), String.t(), map(), String.t() | nil) :: {String.t(), map()}
  def wrap(settings, state, action, args, from) do
    if enabled?(settings) and action in @actions do
      prior = List.last(StatusSync.operations(state)) || %{}
      source = from || prior["observed"] || prior["from"] || settings.project.states["working"]
      {"lifecycle", %{"action" => action, "args" => args, "from" => source, "repo" => settings.repo, "reason" => reason(action, args)}}
    else
      {action, args}
    end
  end

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(args) do
    if is_map(args) and args["action"] in @actions and
         Enum.sort(Map.keys(args)) == ~w(action args from reason repo) and
         StatusSync.validate("status_transition", %{args | "action" => "block", "args" => %{"reason" => args["reason"]}}) == :ok,
       do: Command.validate(args["action"], args["args"]),
       else: {:error, :invalid_lifecycle_event}
  end

  @spec apply(map(), map()) :: {:ok, map()} | {:error, atom()}
  def apply(state, command) do
    args = command["args"]

    with :ok <- validate(args),
         {:ok, next} <- State.apply_command(state, args["action"], args["args"]),
         {:ok, next} <- managed(next, args) do
      retain(state, keep_hold(state, next, args["action"]), command)
    end
  end

  defp managed(state, %{"action" => "effect_request", "args" => args}) do
    state = put_in(state, ["cycle", "effects", args["operation_id"], "status_owner"], "controller")
    if args["kind"] == "block", do: State.apply_command(state, "block", %{"reason" => "agent_requested_human_decision"}), else: {:ok, state}
  end

  defp managed(%{"cycle" => cycle} = state, %{"action" => "operator_decision", "args" => %{"kind" => "pause"}}) when is_map(cycle),
    do: State.apply_command(state, "block", %{"reason" => "operator_pause"})

  defp managed(state, _), do: {:ok, state}

  defp keep_hold(%{"cycle" => %{"phase" => "needs_human_decision"} = old}, %{"cycle" => cycle} = next, "deployment") when is_map(cycle),
    do: put_in(next, ["cycle"], %{cycle | "phase" => "needs_human_decision", "block_reason" => old["block_reason"]})

  defp keep_hold(_, next, _), do: next

  defp retain(%{"cycle" => nil}, %{"cycle" => nil} = next, _), do: {:ok, next}

  defp retain(before, next, command) do
    cycle = next["cycle"] || next["last_cycle"]
    prior = before |> StatusSync.operations() |> Enum.filter(&(&1["cycle_id"] == cycle["id"] and &1["task"] == cycle["task"])) |> List.last()
    role = target(cycle, command["args"], prior)

    if prior == nil or prior["role"] != role or prior["evidence"] != StatusSync.evidence(cycle), do: StatusSync.record(next, command, cycle, role), else: {:ok, next}
  end

  defp target(%{"phase" => phase}, _, _) when phase in ~w(needs_human_decision cancelling cancelled), do: "blocked"
  defp target(%{"phase" => phase}, _, _) when phase in ~w(completed recovered), do: "production_ready"
  defp target(%{"phase" => phase}, _, _) when phase in ~w(awaiting_deployment awaiting_validation), do: "dev_validation"
  defp target(%{"phase" => "awaiting_review"}, %{"action" => "operator_decision", "args" => %{"kind" => "review_started"}}, _), do: "review"
  defp target(%{"phase" => "awaiting_review"}, _, %{"role" => "review"}), do: "review"
  defp target(%{"phase" => "awaiting_review"}, _, _), do: "handoff"
  defp target(%{"phase" => phase}, _, _) when phase in ~w(reserved working awaiting_ci), do: "working"
  defp reason("operator_decision", args), do: args["reason"]
  defp reason(action, args), do: args["reason"] || "Controller event: #{action}"
end
