defmodule SymphonyElixir.Operator.Policy do
  @moduledoc "Server-owned forms and narrow decisions derived from fresh, scope-bound observations."
  alias SymphonyElixir.DeliveryGate.{Command, StatusSync}
  alias SymphonyElixir.GitHubProjects.Delivery.QueueConfirmation
  alias SymphonyElixir.Operator.Decision

  @ordinary ~w(manual_dev_validation_required task_pr_not_bound awaiting_review_or_merge pr_draft
    pr_closed_without_merge pr_ci_failure operator_cancel_pending recovery_owner_retained)
  @broken ~w(deployment_failure deployment_cancelled deployment_timed_out deployment_startup_failure resume_queue_before_dev_validation)
  @fields ~w(initial_minutes fix_minutes fixes ci_attempts retries_per_sha)

  @spec stamp(map() | nil) :: String.t() | nil
  def stamp(nil), do: nil
  def stamp(observation), do: hash(Map.take(observation.facts, ~w(dev_sha deployment pr ci project suspended_pr watch_digest policy_hashes)))

  @spec hash(term()) :: String.t()
  def hash(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])) |> Base.encode16(case: :lower)

  @spec build(map(), map(), map() | nil, map(), map()) :: {:ok, map()} | {:error, atom()}
  def build(form, payload, observation, settings, state) when is_map(payload) do
    with true <- text?(payload["reason"]),
         :ok <- conditions(form.action, observation, state),
         {:ok, data} <- data(form.action, payload, observation, settings, state, form.id) do
      args = %{"kind" => form.action, "actor" => form.actor, "reason" => String.trim(payload["reason"]), "request_hash" => hash(payload), "data" => data}
      with :ok <- Decision.validate(args), do: {:ok, args}
    else
      false -> {:error, :operator_reason_required}
      error -> error
    end
  end

  def build(_, _, _, _, _), do: {:error, :invalid_operator_payload}

  @spec healthy?(map()) :: boolean()
  def healthy?(%{facts: facts}) do
    deployment = facts["deployment"] || %{}
    deployment["result"] == "success" and deployment["environment_ready"] == true and deployment["sha"] == facts["dev_sha"]
  end

  defp conditions(action, _, _) when action in ~w(pause problem cancel), do: :ok

  defp conditions("unpause", observation, state) do
    cycle = state["cycle"]

    cond do
      observation == nil or not observation.complete -> {:error, :observation_required}
      not Decision.stopped?(cycle) -> {:error, :work_unresolved}
      true -> :ok
    end
  end

  defp conditions("recheck_status", observation, state) do
    ready = observation != nil and observation.complete and Decision.stopped?(state["cycle"])
    if ready, do: :ok, else: {:error, :work_unresolved}
  end

  defp conditions(action, observation, state) do
    allowed = allowed_reasons(action)

    cond do
      observation == nil or not observation.complete -> {:error, :observation_required}
      not Enum.all?(observation.reasons, &(&1 in allowed)) -> {:error, :remote_delivery_blocked}
      not Decision.quiet?(state["cycle"]) -> {:error, :work_unresolved}
      not environment_allowed?(action, observation) -> {:error, :environment_not_ready}
      true -> :ok
    end
  end

  defp allowed_reasons("recovery"), do: @ordinary ++ @broken
  defp allowed_reasons("confirm_queue"), do: @ordinary ++ ["resume_queue_before_dev_validation"]
  defp allowed_reasons(_), do: @ordinary
  defp environment_allowed?("recovery", _), do: true
  defp environment_allowed?("confirm_queue", observation), do: QueueConfirmation.candidate?(observation)
  defp environment_allowed?(_, observation), do: healthy?(observation)

  defp data("confirm_queue", payload, obs, _, _, _) do
    if keys?(payload, ~w(reason criteria queue_resource scheduler_resource)) do
      {:ok,
       QueueConfirmation.proof_binding(obs)
       |> Map.merge(Map.take(payload, ~w(criteria queue_resource scheduler_resource)))
       |> Map.merge(%{"source" => "operator_manual", "confirmed_at_ms" => obs.facts["controller_now_ms"]})}
    else
      {:error, :invalid_operator_payload}
    end
  end

  defp data(action, payload, _, _, _, _) when action in ~w(pause problem cancel unpause) do
    if keys?(payload, ~w(reason)), do: {:ok, %{}}, else: {:error, :invalid_operator_payload}
  end

  defp data("review_started", payload, obs, settings, state, _) do
    work = get_in(state, ["cycle", "work"]) || %{}
    valid = review_evidence?(obs.facts, work)
    if valid and keys?(payload, ~w(reason)) and settings.project.states["review"] != nil and not Decision.held?(state), do: {:ok, %{}}, else: {:error, :review_not_ready}
  end

  defp data("validation_failed", payload, obs, _, _, _) do
    if keys?(payload, ~w(reason)), do: {:ok, Map.put(proof(obs), "criteria", ["Operator rejected development validation"])}, else: {:error, :invalid_operator_payload}
  end

  defp data("recheck_status", payload, _, _, state, _) do
    op = Enum.find(StatusSync.operations(state), &(&1["status"] not in ~w(confirmed superseded)))
    if keys?(payload, ~w(reason)) and op, do: {:ok, %{"operation_id" => op["id"]}}, else: {:error, :status_result_not_allowed}
  end

  defp data("validate", payload, obs, _, state, _) do
    if keys?(payload, ~w(reason criteria)) and payload["criteria"] == Decision.criteria() and
         (state["cycle"] != nil or obs.facts["open_pr_numbers"] == []),
       do: {:ok, Map.put(proof(obs), "criteria", Decision.criteria())},
       else: {:error, :criteria_required}
  end

  defp data("extend_budget", payload, _, _, _, _) do
    if keys?(payload, ["reason" | @fields]), do: limits(payload, false), else: {:error, :invalid_operator_payload}
  end

  defp data("recovery", payload, obs, settings, _, id) do
    with true <- keys?(payload, ["reason", "item_id" | @fields]),
         {:ok, row} <- eligible(obs, settings, payload["item_id"]),
         {:ok, limits} <- limits(payload, true) do
      {:ok,
       Map.merge(limits, %{"item_id" => row["item_id"], "issue_id" => row["native_ref"]["issue_id"], "sha" => obs.facts["dev_sha"], "branch" => "agent/recovery-" <> String.slice(hash(id), 0, 24)})}
    else
      false -> {:error, :invalid_operator_payload}
      error -> error
    end
  end

  defp data("resume", payload, obs, settings, %{"cycle" => %{"work" => %{"merge_sha" => sha}}} = state, _) when is_binary(sha) do
    pr = obs.facts["pr"] || %{}
    cycle = state["cycle"]
    row = Enum.find(get_in(obs.facts, ["project", "items"]) || [], &(&1["item_id"] == cycle["task"]["item_id"]))

    bound = pr["state"] == "merged" and pr["ancestry"] == "included" and pr["merge_sha"] == sha and pr["number"] == cycle["work"]["pr_number"]
    item = owned_post_merge?(row, settings, cycle)

    if keys?(payload, ~w(reason)) and bound and item,
      do: {:ok, %{"sha" => obs.facts["dev_sha"]}},
      else: {:error, :owned_allowed_item_required}
  end

  defp data("resume", payload, obs, settings, state, _) do
    with true <- keys?(payload, ~w(reason)),
         {:ok, _} <- resumable(obs, settings, get_in(state, ["cycle", "task"])),
         :ok <- baseline(state, obs) do
      {:ok, %{"sha" => obs.facts["dev_sha"]}}
    else
      false -> {:error, :invalid_operator_payload}
      error -> error
    end
  end

  defp data("review_resume", payload, obs, settings, state, _) do
    pr = obs.facts["pr"] || %{}
    work = get_in(state, ["cycle", "work"]) || %{}

    with true <- keys?(payload, ["reason" | @fields]),
         true <- pr["state"] == "open" and pr["number"] == work["pr_number"] and pr["head_sha"] == work["head_sha"],
         {:ok, _} <- eligible(obs, settings, get_in(state, ["cycle", "task", "item_id"]), review_states(settings)),
         :ok <- baseline(state, obs),
         {:ok, limits} <- limits(payload, false) do
      {:ok, Map.merge(limits, %{"sha" => obs.facts["dev_sha"], "head_sha" => pr["head_sha"], "pr_number" => pr["number"]})}
    else
      false -> {:error, :review_context_changed}
      error -> error
    end
  end

  defp data("finish_cancel", payload, obs, _, state, _) do
    pr = obs.facts["pr"]

    with true <- keys?(payload, ~w(reason)),
         true <- is_nil(pr) or pr["state"] == "closed",
         :ok <- baseline(state, obs) do
      {:ok, Map.put(proof(obs), "criteria", ["Stopped worker and checked closed or absent PR"])}
    else
      false -> {:error, :close_pr_or_validate_merged_dev}
      error -> error
    end
  end

  defp baseline(state, obs) do
    if Command.proof(state["baseline"] || %{}) == proof(obs) and not Decision.held?(%{state | "operator_pause" => nil}),
      do: :ok,
      else: {:error, :unvalidated_base}
  end

  defp owned_post_merge?(row, settings, cycle) do
    row != nil and row["archived"] == false and row["native_ref"]["issue_id"] == cycle["task"]["issue_id"] and row["native_ref"]["repo"] == settings.repo and
      (settings.project.item_ids == nil or row["item_id"] in settings.project.item_ids)
  end

  defp review_evidence?(facts, work) do
    pr = facts["pr"] || %{}
    ci = facts["ci"] || %{}

    pr["state"] == "open" and pr["number"] == work["pr_number"] and pr["head_sha"] == work["head_sha"] and
      ci["result"] == "success" and ci["head_sha"] == work["head_sha"] and ci["base_sha"] == facts["dev_sha"]
  end

  defp resumable(obs, settings, %{"item_id" => id, "issue_id" => issue_id}) do
    with {:ok, row} <- eligible(obs, settings, id, resume_states(settings)),
         true <- row["native_ref"]["issue_id"] == issue_id do
      {:ok, row}
    else
      _ -> {:error, :owned_allowed_item_required}
    end
  end

  defp resumable(_, _, _), do: {:error, :owned_allowed_item_required}

  defp resume_states(settings), do: if(settings.project.states["review"], do: ~w(ready working blocked), else: ~w(ready working))
  defp review_states(settings), do: if(settings.project.states["review"], do: ~w(ready working blocked handoff review), else: ~w(ready))

  defp eligible(obs, settings, id, states \\ ["ready"]) do
    row = Enum.find(get_in(obs.facts, ["project", "items"]) || [], &(&1["item_id"] == id))

    if eligible_row?(row, settings, states) and (is_nil(settings.project.item_ids) or id in settings.project.item_ids),
      do: {:ok, row},
      else: {:error, :ready_allowed_item_required}
  end

  defp eligible_row?(nil, _, _), do: false

  defp eligible_row?(row, settings, states) do
    allowed = row["eligible"] == true or (row["agent_allowed"] == true and row["in_scope"] == true and Enum.all?(row["reasons"] || [], &(&1 == "inactive_status")))

    allowed and row["archived"] == false and row["issue_state"] == "OPEN" and
      row["state"] in Enum.map(states, &settings.project.states[&1]) and row["native_ref"]["repo"] == settings.repo
  end

  defp limits(payload, recovery?) do
    values = Enum.map(@fields, &number(payload[&1]))

    if valid_limits?(values) do
      [initial, fix, fixes, ci, retries] = values

      data = %{
        "initial_ms" => initial * 60_000,
        "fix_ms" => fix * 60_000,
        "fixes" => fixes,
        "ci_attempts" => ci,
        "retries_per_sha" => retries
      }

      positive_limits(data, recovery?)
    else
      {:error, :invalid_operator_budget}
    end
  end

  defp valid_limits?(values) do
    values |> Enum.zip([1440, 1440, 100, 100, 100]) |> Enum.all?(fn {n, ceiling} -> is_integer(n) and n in 0..ceiling end)
  end

  defp positive_limits(data, recovery?) do
    if Enum.any?(Map.values(data), &(&1 > 0)) and (not recovery? or (data["initial_ms"] > 0 and data["ci_attempts"] > 0)), do: {:ok, data}, else: {:error, :positive_budget_required}
  end

  defp number(""), do: 0

  defp number(value) when is_binary(value) and byte_size(value) <= 4 do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp number(_), do: nil
  defp proof(obs), do: Command.proof(obs.facts["deployment"] || %{})
  defp keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..2048 and String.trim(value) != ""
end
