defmodule SymphonyElixir.DeliveryRuntime.Policy do
  @moduledoc "Admission policy for verified observations; no remote or store writes."

  alias SymphonyElixir.DeliveryGate.Command
  alias SymphonyElixir.Tracker.Issue

  @ordinary ~w(manual_dev_validation_required task_pr_not_bound awaiting_review_or_merge pr_draft)
  @recovery ~w(recovery_owner_retained deployment_failure deployment_cancelled deployment_timed_out
    deployment_startup_failure resume_queue_before_dev_validation)

  @spec admission(map(), map(), map(), Issue.t()) :: :ok | {:error, atom()}
  def admission(settings, state, observation, issue) do
    cycle = state["cycle"]
    rows = observation.facts["project"]["items"] || []
    row = Enum.find(rows, &(&1["item_id"] == issue.id))
    allowed = allowed_reasons(cycle)

    cond do
      not match?(%Issue{dispatchable: true, native_ref: %{}}, issue) -> {:error, :task_permission_required}
      not eligible?(settings, row, issue) -> {:error, :task_permission_required}
      not owns?(cycle, issue.id) -> {:error, :cycle_occupied}
      is_nil(cycle) and row["state"] != settings.project.states["ready"] -> {:error, :new_task_not_ready}
      not Enum.all?(observation.reasons, &(&1 in allowed)) -> {:error, :remote_delivery_blocked}
      true -> check_base(cycle, state, observation)
    end
  end

  defp owns?(nil, _), do: true
  defp owns?(cycle, item), do: cycle["task"]["item_id"] == item and cycle["phase"] == "reserved"
  defp allowed_reasons(nil), do: @ordinary

  defp allowed_reasons(cycle) do
    @ordinary ++
      if(cycle["recovery"], do: @recovery, else: []) ++
      if(cycle["budget"]["fixes"] > 0, do: ["pr_ci_failure"], else: [])
  end

  defp check_base(%{"recovery" => recovery} = cycle, _, observation) when not is_nil(recovery),
    do: recovery_base(cycle, observation)

  defp check_base(_, state, observation), do: validated_base(state, observation)

  defp eligible?(settings, row, issue) do
    is_map(row) and row["eligible"] == true and row["issue_state"] == "OPEN" and row["archived"] == false and
      row["native_ref"]["issue_id"] == issue.native_ref["issue_id"] and
      row["native_ref"]["repo"] == settings.repo and issue.native_ref["repo"] == settings.repo and
      selected?(settings.project.item_ids, issue.id) and
      row["state"] in [settings.project.states["ready"], settings.project.states["working"]]
  end

  defp selected?(nil, _), do: true
  defp selected?(ids, item), do: item in ids

  defp validated_base(state, observation) do
    baseline = state["baseline"]
    deployment = observation.facts["deployment"] || %{}

    if is_map(baseline) and baseline["sha"] == observation.facts["dev_sha"] and
         Command.proof(baseline) == Command.proof(deployment) and deployment["result"] == "success" and
         deployment["environment_ready"] == true do
      :ok
    else
      {:error, :unvalidated_base}
    end
  end

  defp recovery_base(cycle, observation) do
    if cycle["work"]["base_sha"] == observation.facts["dev_sha"], do: :ok, else: {:error, :recovery_base_changed}
  end

  @spec new_command?(map(), map()) :: boolean()
  def new_command?(%{action: "observe_ci", args: args}, state) do
    existing = get_in(state, ["cycle", "budget", "ci", args["reservation_id"]]) || %{}
    Map.take(existing, ~w(run_id run_attempt result)) != Map.take(args, ~w(run_id run_attempt result))
  end

  def new_command?(%{action: "deployment", args: args}, state), do: state["cycle"]["deployment"] != args
  def new_command?(_, _), do: true

  @spec cleanup(map(), String.t()) :: :ok | {:error, atom()}
  def cleanup(%{mode: :reconciled, state: %{"status" => "idle", "cycle" => nil, "last_cycle" => last}}, path)
      when is_map(last) do
    task = last["task"]["item_id"]
    expected = "GHP-" <> Base.encode16(task, case: :lower)
    if Path.basename(path) == expected, do: :ok, else: {:error, :workspace_ownership_unconfirmed}
  end

  def cleanup(_, _), do: {:error, :workspace_cycle_retained}
end
