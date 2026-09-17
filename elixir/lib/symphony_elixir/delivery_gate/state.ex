defmodule SymphonyElixir.DeliveryGate.State do
  @moduledoc "Pure delivery-cycle transitions. Inputs are verified controller facts, not GitHub responses."

  alias SymphonyElixir.DeliveryGate.{Budget, Command, Effects}

  @budget_commands ~w(start_work checkpoint stop_work resolve_interval reserve_ci observe_ci external_ci begin_fix extend_budget confirm_ci_not_started)
  @budget_errors [:time_budget_exhausted, :fix_budget_exhausted, :ci_budget_exhausted, :retry_budget_exhausted]

  @spec new() :: map()
  def new, do: %{"status" => "bootstrap_required", "baseline" => nil, "cycle" => nil, "last_cycle" => nil}

  @spec apply_command(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def apply_command(state, action, args) do
    with :ok <- Command.validate(action, args), do: transition(state, action, args)
  end

  @spec admission(map(), String.t()) :: :ok | {:error, atom()}
  def admission(%{"status" => "idle", "cycle" => nil}, "new"), do: :ok

  def admission(%{"cycle" => %{"task" => %{"item_id" => item}, "phase" => "reserved", "budget" => budget} = cycle}, item) do
    if quiet?(cycle) and Budget.work_available?(budget),
      do: :ok,
      else: {:error, :work_unresolved}
  end

  def admission(_, _), do: {:error, :cycle_blocked}

  defp transition(%{"status" => "bootstrap_required", "cycle" => nil} = state, "bootstrap", args) do
    {:ok, %{state | "status" => "idle", "baseline" => validated_proof(args)}}
  end

  defp transition(%{"cycle" => nil} = state, "record_restore", _args), do: {:ok, state}
  defp transition(state, "record_restore", _args), do: put_cycle(state, uncertain_cycle(state["cycle"]))

  defp transition(%{"status" => "idle", "cycle" => nil} = state, "reserve", args) do
    if args["sha"] == state["baseline"]["sha"] do
      cycle = %{
        "id" => args["cycle_id"],
        "owner" => task(args),
        "task" => task(args),
        "phase" => "reserved",
        "work" => work(args),
        "budget" => Budget.new(),
        "deployment" => nil,
        "validation" => nil,
        "block_reason" => nil,
        "cancellation" => nil,
        "recovery" => nil,
        "suspended" => nil,
        "effects" => %{}
      }

      {:ok, %{state | "status" => "occupied", "cycle" => cycle}}
    else
      {:error, :unvalidated_base}
    end
  end

  defp transition(%{"cycle" => nil}, _, _), do: {:error, :no_active_cycle}

  defp transition(state, action, args) when action in ~w(effect_request effect_submit effect_sent effect_confirm effect_candidate) do
    with {:ok, cycle} <- Effects.apply_command(state["cycle"], action, args), do: put_cycle(state, cycle)
  end

  defp transition(state, "bind_pr", args) do
    cycle = state["cycle"]
    ci = Budget.latest_ci(cycle["budget"])

    if Budget.stopped?(cycle["budget"]) and cycle["phase"] in ~w(awaiting_ci cancelling) and is_map(ci) and ci["sha"] == args["sha"] and
         cycle["work"]["pr_number"] in [nil, args["pr_number"]] do
      put_cycle(state, %{cycle | "work" => Map.merge(cycle["work"], %{"pr_number" => args["pr_number"], "head_sha" => args["sha"]})})
    else
      {:error, :pr_binding_not_allowed}
    end
  end

  defp transition(state, "manual_ci", args) do
    cycle = state["cycle"]
    prior = Budget.latest_ci(cycle["budget"])
    id = "manual-#{args["run_id"]}-#{args["run_attempt"]}"
    request = %{"reservation_id" => id, "sha" => args["sha"], "retry" => true, "reason" => "Observed manual GitHub rerun"}
    result = args |> Map.take(~w(run_id run_attempt result)) |> Map.put("reservation_id", id)

    with true <- cycle["phase"] == "awaiting_ci" and cycle["cancellation"] == nil and is_map(prior),
         true <- matching_rerun?(prior, args),
         {:ok, budget} <- Budget.apply_command(cycle["budget"], "reserve_ci", request),
         {:ok, budget} <- Budget.apply_command(budget, "observe_ci", result) do
      put_cycle(state, %{cycle | "budget" => budget})
    else
      false -> {:error, :manual_ci_not_allowed}
      {:error, reason} when reason in @budget_errors -> put_cycle(state, block(cycle, Atom.to_string(reason)))
      error -> error
    end
  end

  defp transition(state, action, args) when action in @budget_commands do
    cycle = state["cycle"]

    with :ok <- budget_phase(cycle, action, args),
         {:ok, budget} <- Budget.apply_command(cycle["budget"], action, args) do
      phase = budget_phase_after(cycle["phase"], action)
      updated = %{cycle | "budget" => budget, "phase" => phase}
      updated = if action == "begin_fix", do: Effects.finish_attempt(updated), else: updated
      updated = if Budget.exhausted?(budget), do: block(updated, "time_budget_exhausted"), else: updated
      {:ok, %{state | "cycle" => updated}}
    else
      {:error, reason} when reason in @budget_errors ->
        put_cycle(state, block(cycle, Atom.to_string(reason)))

      {:error, _} = error ->
        error
    end
  end

  defp transition(state, "handoff", args) do
    cycle = state["cycle"]
    latest = Budget.latest_ci(cycle["budget"])

    cond do
      cycle["phase"] != "awaiting_ci" ->
        {:error, :invalid_phase}

      not quiet?(cycle) ->
        {:error, :work_unresolved}

      is_nil(latest) or latest["sha"] != args["sha"] or latest["result"] != "success" ->
        {:error, :ci_not_successful}

      cycle["work"]["pr_number"] not in [nil, args["pr_number"]] ->
        {:error, :pr_changed}

      true ->
        work = Map.merge(cycle["work"], %{"pr_number" => args["pr_number"], "head_sha" => args["sha"]})
        put_cycle(state, %{cycle | "work" => work, "phase" => "awaiting_review"})
    end
  end

  defp transition(state, "merged", args) do
    cycle = state["cycle"]

    if cycle["phase"] in ["awaiting_review", "cancelling"] and quiet?(cycle) and
         args["pr_number"] == cycle["work"]["pr_number"] do
      updated = put_in(cycle, ["work", "merge_sha"], args["sha"])
      put_cycle(state, %{updated | "phase" => next_phase(cycle, "awaiting_deployment"), "validation" => nil})
    else
      {:error, :merge_not_expected}
    end
  end

  defp transition(state, "deployment", args) do
    cycle = state["cycle"]

    if quiet?(cycle) and cycle["phase"] in ["awaiting_deployment", "awaiting_validation", "needs_human_decision", "cancelling"] do
      updated = %{cycle | "deployment" => args, "validation" => nil}

      updated =
        if args["result"] == "success" and args["environment_ready"] do
          %{updated | "phase" => next_phase(cycle, "awaiting_validation"), "block_reason" => nil}
        else
          block(updated, deployment_reason(args))
        end

      put_cycle(state, updated)
    else
      {:error, :deployment_not_expected}
    end
  end

  defp transition(state, "validate_dev", args) do
    cycle = state["cycle"]
    deployment = cycle["deployment"]

    if quiet?(cycle) and is_map(deployment) and deployment["result"] == "success" and
         deployment["environment_ready"] and Command.proof(deployment) == Command.proof(args) do
      updated = validated_cycle(cycle, args)
      put_cycle(state, updated)
    else
      {:error, :validation_not_current}
    end
  end

  defp transition(state, "complete", args) do
    cycle = state["cycle"]

    if cycle["recovery"] == nil and cycle["cancellation"] == nil and cycle["phase"] == "awaiting_validation" and
         cycle["work"]["merge_sha"] != nil and ready?(cycle, args) do
      close_cycle(state, "completed", args)
    else
      {:error, :cycle_not_complete}
    end
  end

  defp transition(state, "block", args), do: put_cycle(state, block(state["cycle"], args["reason"]))

  defp transition(state, "request_cancel", args) do
    cycle = state["cycle"]

    if cycle["cancellation"] == nil do
      put_cycle(state, Effects.cancel(%{cycle | "cancellation" => args, "phase" => "cancelling", "block_reason" => "operator_cancel_requested"}))
    else
      {:error, :cancellation_already_requested}
    end
  end

  defp transition(state, "finish_cancel", args) do
    cycle = state["cycle"]

    cond do
      cycle["cancellation"] == nil ->
        {:error, :cancellation_not_requested}

      not quiet?(cycle) ->
        {:error, :work_unresolved}

      cycle["work"]["merge_sha"] != nil and not ready?(cycle, args) ->
        {:error, :merged_environment_unvalidated}

      cycle["recovery"] != nil ->
        put_cycle(state, block(cycle["suspended"], "recovery_cancelled"))

      true ->
        close_cycle(state, "cancelled", args)
    end
  end

  defp transition(state, "assign_recovery", args) do
    cycle = state["cycle"]

    cond do
      cycle["phase"] != "needs_human_decision" ->
        {:error, :recovery_not_needed}

      not quiet?(cycle) ->
        {:error, :work_unresolved}

      cycle["recovery"] != nil or cycle["cancellation"] != nil ->
        {:error, :recovery_unresolved}

      task(args) == cycle["owner"] or args["branch"] == cycle["work"]["branch"] ->
        {:error, :recovery_requires_new_task}

      true ->
        recovery = %{
          cycle
          | "task" => task(args),
            "work" => work(args),
            "budget" => Budget.new(args),
            "phase" => "reserved",
            "deployment" => nil,
            "validation" => nil,
            "block_reason" => nil,
            "effects" => %{},
            "recovery" => Map.take(args, ["actor", "reason", "sha"]),
            "suspended" => cycle
        }

        put_cycle(state, recovery)
    end
  end

  defp transition(state, "finish_recovery", args) do
    cycle = state["cycle"]

    if cycle["recovery"] != nil and cycle["cancellation"] == nil and cycle["work"]["merge_sha"] != nil and ready?(cycle, args) do
      primary = cycle["suspended"]

      if primary["work"]["merge_sha"] != nil do
        close_cycle(state, "recovered", args)
      else
        restored = block(primary, "base_reconciliation_required")
        {:ok, %{state | "cycle" => restored, "baseline" => cycle["validation"]}}
      end
    else
      {:error, :recovery_not_complete}
    end
  end

  defp transition(state, "resume", args) do
    cycle = state["cycle"]

    if cycle["phase"] == "needs_human_decision" and quiet?(cycle) and cycle["cancellation"] == nil and
         cycle["work"]["merge_sha"] == nil and args["sha"] == state["baseline"]["sha"] do
      put_cycle(state, %{cycle | "phase" => "reserved", "block_reason" => nil})
    else
      {:error, :resume_not_allowed}
    end
  end

  defp transition(state, "review_resume", args) do
    cycle = state["cycle"]
    bucket = if cycle["budget"]["fixes"] == 0, do: "initial_ms", else: "fix_ms"

    if review_matches?(cycle, args) and quiet?(cycle) and args["sha"] == state["baseline"]["sha"] and
         args[bucket] > 0 do
      extension = Map.drop(args, ~w(sha head_sha pr_number))
      {:ok, budget} = Budget.apply_command(cycle["budget"], "extend_budget", extension)
      put_cycle(state, Effects.finish_attempt(%{cycle | "budget" => budget, "phase" => "reserved", "block_reason" => nil}))
    else
      {:error, :review_resume_not_allowed}
    end
  end

  defp transition(_, _, _), do: {:error, :invalid_phase}

  defp matching_rerun?(prior, args) do
    prior["run_id"] == args["run_id"] and prior["sha"] == args["sha"] and
      is_integer(prior["run_attempt"]) and prior["run_attempt"] + 1 == args["run_attempt"]
  end

  defp review_matches?(cycle, args) do
    cycle["phase"] == "awaiting_review" and cycle["cancellation"] == nil and
      cycle["work"]["merge_sha"] == nil and cycle["work"]["pr_number"] == args["pr_number"] and
      cycle["work"]["head_sha"] == args["head_sha"]
  end

  defp budget_phase(cycle, "start_work", args) do
    expected = if cycle["budget"]["fixes"] == 0, do: "initial", else: "fix"

    cond do
      cycle["phase"] != "reserved" -> {:error, :invalid_phase}
      args["budget"] != expected -> {:error, :wrong_time_budget}
      true -> :ok
    end
  end

  defp budget_phase(cycle, "begin_fix", _) do
    cond do
      Effects.sent?(cycle) -> {:error, :publication_unresolved}
      cycle["phase"] != "awaiting_ci" -> {:error, :invalid_phase}
      not match?(%{"result" => "failure"}, Budget.latest_ci(cycle["budget"])) -> {:error, :ci_failure_required}
      true -> :ok
    end
  end

  defp budget_phase(cycle, "reserve_ci", _) do
    if cycle["phase"] in ["reserved", "awaiting_ci"], do: :ok, else: {:error, :invalid_phase}
  end

  defp budget_phase(_, _, _), do: :ok
  defp deployment_reason(%{"result" => "success"}), do: "environment_not_ready"
  defp deployment_reason(_), do: "deployment_unconfirmed"

  defp budget_phase_after(_, "start_work"), do: "working"
  defp budget_phase_after("working", "stop_work"), do: "reserved"
  defp budget_phase_after(_, "begin_fix"), do: "reserved"
  defp budget_phase_after(_, "reserve_ci"), do: "awaiting_ci"
  defp budget_phase_after(phase, _), do: phase

  defp task(args), do: Map.take(args, ["item_id", "issue_id"])

  defp work(args) do
    %{"branch" => args["branch"], "base_sha" => args["sha"], "head_sha" => nil, "pr_number" => nil, "merge_sha" => nil}
  end

  defp quiet?(cycle), do: Budget.stopped?(cycle["budget"]) and not Budget.unresolved?(cycle["budget"]) and not Effects.unresolved?(cycle)
  defp put_cycle(state, cycle), do: {:ok, %{state | "cycle" => cycle}}

  defp block(cycle, reason) do
    %{cycle | "phase" => next_phase(cycle, "needs_human_decision"), "block_reason" => reason, "validation" => nil}
  end

  defp next_phase(%{"cancellation" => nil}, phase), do: phase
  defp next_phase(_, _), do: "cancelling"

  defp validated_cycle(cycle, %{"passed" => true} = args) do
    %{cycle | "validation" => args, "phase" => next_phase(cycle, "awaiting_validation"), "block_reason" => nil}
  end

  defp validated_cycle(cycle, args), do: Map.put(block(cycle, "manual_validation_failed"), "validation", args)

  defp uncertain_cycle(cycle) do
    suspended = if cycle["suspended"], do: uncertain_cycle(cycle["suspended"]), else: nil
    updated = %{cycle | "budget" => Budget.mark_uncertain(cycle["budget"]), "suspended" => suspended}
    block(updated, "restored_accounting_requires_operator")
  end

  defp ready?(cycle, args) do
    quiet?(cycle) and match?(%{"passed" => true}, cycle["validation"]) and
      Command.proof(cycle["validation"]) == Command.proof(args) and
      Command.proof(cycle["deployment"]) == Command.proof(args)
  end

  defp validated_proof(args), do: Map.merge(Command.proof(args), Map.take(args, ["actor", "reason", "criteria"]))

  defp close_cycle(state, result, args) do
    closed = Map.merge(state["cycle"], %{"phase" => result, "completion" => args})
    {:ok, %{state | "status" => "idle", "cycle" => nil, "last_cycle" => closed, "baseline" => Command.proof(args)}}
  end
end
