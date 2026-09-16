defmodule SymphonyElixir.GitHubProjects.Delivery.Evidence do
  @moduledoc "Cross-check attempt-bound receipts against pinned policy and GitHub jobs."

  alias SymphonyElixir.GitHubProjects.Delivery.{Archive, JSON, Settings}

  @identity ~w(repository workflow_ref event ref sha run_id run_attempt)
  @receipt_keys ~w(schema_version job checkout_sha admitted success steps facts errors)
  @report_keys ~w(schema_version workflow observed_at current_dev_sha freshness deployment environment manual_validation next_task_allowed jobs errors)
  @outcomes ~w(success failure cancelled skipped unknown)
  @facts %{
    "scheduler_freeze" => %{"freeze_started" => ~w(true false), "cron_disabled" => ~w(true false), "initial_cron_state" => ~w(configured disabled)},
    "queue_pause" => %{"initial_state" => ~w(active paused), "resume_required" => ~w(true false), "cutover_started" => ~w(true false), "guard_established" => ~w(true false)},
    "scheduler_finalize" => %{"state" => ~w(configured disabled)},
    "queue_finalize" => %{"state" => ~w(active paused), "reason" => ~w(resumed inherited_pause protective_pause unconfirmed)}
  }

  @spec verify(binary(), map(), map(), list(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def verify(zip, artifact, run, jobs, policy, settings) do
    with :ok <- artifact_identity(artifact, run),
         {:ok, raw} <- Archive.read(zip, artifact["digest"]),
         {:ok, report} <- JSON.decode(raw),
         :ok <- report_identity(report, run, settings),
         {:ok, bound_jobs} <- bind_jobs(jobs, run, policy.jobs),
         :ok <- validate_receipts(report, policy, run, settings),
         {:ok, result} <- evaluate(report, bound_jobs, policy, run) do
      {:ok, Map.merge(result, %{artifact_id: artifact["id"], digest: artifact["digest"], observed_at: report["observed_at"]})}
    end
  rescue
    _ -> {:error, :invalid_deployment_evidence}
  end

  @spec bind_jobs(list(), map(), map()) :: {:ok, map()} | {:error, :jobs_not_bound}
  def bind_jobs(jobs, run, mapping) do
    if is_list(jobs) and length(jobs) == map_size(mapping) and length(Enum.uniq_by(jobs, & &1["id"])) == length(jobs) and
         Enum.all?(
           jobs,
           &(Settings.id?(&1["id"]) and &1["run_id"] == run["id"] and
               &1["run_attempt"] == run["run_attempt"] and &1["head_sha"] == run["head_sha"])
         ) do
      bind_names(jobs, mapping)
    else
      {:error, :jobs_not_bound}
    end
  end

  defp bind_names(jobs, mapping) do
    Enum.reduce_while(mapping, {:ok, %{}}, fn {key, expected}, {:ok, acc} ->
      case Enum.filter(jobs, &(&1["name"] == expected.name)) do
        [job] -> {:cont, {:ok, Map.put(acc, key, job)}}
        _ -> {:halt, {:error, :jobs_not_bound}}
      end
    end)
  end

  @spec successful_job?(map(), [String.t()]) :: boolean()
  def successful_job?(job, required) do
    job["status"] == "completed" and job["conclusion"] == "success" and is_list(job["steps"]) and
      Enum.all?(required, fn name ->
        case Enum.filter(job["steps"], &(&1["name"] == name)) do
          [%{"status" => "completed", "conclusion" => "success"}] -> true
          _ -> false
        end
      end)
  end

  defp artifact_identity(artifact, run) do
    bound = artifact["workflow_run"] || %{}
    name = "development-evidence-#{run["id"]}-#{run["run_attempt"]}"

    expected = %{"id" => run["id"], "head_sha" => run["head_sha"], "head_branch" => "dev", "repository_id" => run["repository"]["id"], "head_repository_id" => run["repository"]["id"]}

    if Settings.id?(artifact["id"]) and artifact["name"] == name and artifact["expired"] == false and
         is_integer(artifact["size_in_bytes"]) and artifact["size_in_bytes"] in 1..5_242_880 and
         Map.take(bound, Map.keys(expected)) == expected do
      :ok
    else
      {:error, :artifact_identity_mismatch}
    end
  end

  defp identity(run, settings) do
    %{
      "repository" => settings.repo,
      "workflow_ref" => settings.repo <> "/" <> settings.policy["deployment_workflow"] <> "@refs/heads/dev",
      "ref" => "refs/heads/dev",
      "event" => run["event"],
      "sha" => run["head_sha"],
      "run_id" => Integer.to_string(run["id"]),
      "run_attempt" => Integer.to_string(run["run_attempt"])
    }
  end

  defp report_identity(report, run, settings) do
    expected = identity(run, settings)

    cond do
      not report_shape?(report) -> {:error, :invalid_evidence_schema}
      report["schema_version"] !== 1 -> {:error, :unsupported_evidence_schema}
      Map.take(report, @identity) != expected -> {:error, :evidence_identity_mismatch}
      report["workflow"] != settings.policy["deployment_workflow"] -> {:error, :evidence_identity_mismatch}
      report["manual_validation"] != "pending" or report["next_task_allowed"] != false -> {:error, :invalid_evidence_decision}
      not observed_during_run?(report["observed_at"], run) -> {:error, :evidence_timestamp_invalid}
      true -> :ok
    end
  end

  defp report_shape?(report) do
    exact_keys?(report, @identity ++ @report_keys) and is_map(report["jobs"]) and is_list(report["errors"])
  end

  defp observed_during_run?(value, run) do
    with {:ok, at, _} <- DateTime.from_iso8601(value),
         {:ok, started, _} <- DateTime.from_iso8601(run["run_started_at"]),
         {:ok, ended, _} <- DateTime.from_iso8601(run["updated_at"]) do
      DateTime.compare(at, started) != :lt and DateTime.compare(at, ended) != :gt
    else
      _ -> false
    end
  end

  defp validate_receipts(report, policy, run, settings) do
    expected = identity(run, settings)

    valid =
      Enum.all?(report["jobs"], fn {name, receipt} ->
        contract = policy.spec["jobs"][name]

        receipt_shape?(receipt, name, expected) and steps_valid?(receipt["steps"], contract) and
          facts_valid?(name, receipt["facts"])
      end)

    if valid, do: :ok, else: {:error, :invalid_job_receipt}
  end

  defp receipt_shape?(receipt, name, expected) do
    exact_keys?(receipt, @identity ++ @receipt_keys) and receipt["schema_version"] === 1 and receipt["job"] == name and
      Map.take(receipt, @identity) == expected and is_boolean(receipt["admitted"]) and is_boolean(receipt["success"]) and
      is_list(receipt["errors"])
  end

  defp steps_valid?(steps, contract) do
    is_map(contract) and is_map(steps) and Enum.sort(Map.keys(steps)) == Enum.sort(contract["observed_steps"]) and
      Enum.all?(steps, fn {_, step} ->
        exact_keys?(step, ~w(outcome conclusion)) and step["outcome"] in @outcomes and step["conclusion"] in @outcomes
      end)
  end

  defp facts_valid?(name, facts) do
    fields = Map.get(@facts, name, %{})
    exact_keys?(facts, Map.keys(fields)) and Enum.all?(fields, fn {key, allowed} -> facts[key] in (allowed ++ ["unknown"]) end)
  end

  defp evaluate(report, jobs, policy, run) do
    failures =
      Enum.flat_map(policy.spec["jobs"], fn {name, spec} ->
        receipt = report["jobs"][name]
        if complete_receipt?(receipt, jobs[name], policy.jobs[name], spec), do: [], else: ["job_incomplete:" <> name]
      end)

    ready_jobs = failures == [] and successful_job?(jobs["deployment_evidence"], policy.jobs["deployment_evidence"].required)
    cloud = cloud_state(report["jobs"])
    status = deployment_status(run, ready_jobs and cloud.valid)
    freshness = freshness(report)
    blockers = if status == "success", do: [], else: ["deployment_not_successful"]
    blockers = blockers ++ freshness_blockers(freshness)
    blockers = if cloud.inherited, do: blockers ++ ["resume_queue_before_dev_validation"], else: blockers
    ready = blockers == []

    if consistent?(report, status, cloud, freshness, blockers) do
      {:ok,
       %{
         deployment: status,
         environment_ready: ready,
         blockers: blockers ++ failures,
         complete: ready_jobs and cloud.valid,
         source: "deployment_evidence",
         queue: cloud.queue,
         scheduler: cloud.scheduler
       }}
    else
      {:error, :evidence_contradicts_github}
    end
  end

  defp complete_receipt?(receipt, job, mapping, spec) when is_map(receipt) do
    required = spec["required_steps"] ++ completion_steps(receipt["job"])

    receipt["admitted"] and receipt["success"] and receipt["errors"] == [] and
      receipt["checkout_sha"] == receipt["sha"] and
      Enum.all?(required, &match?(%{"outcome" => "success", "conclusion" => "success"}, receipt["steps"][&1])) and
      successful_job?(job, Enum.map(required, &Map.fetch!(mapping.steps, &1))) and
      Enum.all?(receipt["steps"], fn {id, step} ->
        case Enum.filter(job["steps"], &(&1["name"] == mapping.steps[id])) do
          [actual] -> actual["conclusion"] == step["conclusion"]
          _ -> false
        end
      end)
  end

  defp complete_receipt?(_, _, _, _), do: false

  defp completion_steps("scheduler_finalize"), do: ["verify_restored_cron"]
  defp completion_steps("queue_finalize"), do: ["resume_queue"]
  defp completion_steps(_), do: []

  defp cloud_state(jobs) do
    start = get_in(jobs, ["queue_pause", "facts"]) || %{}
    queue = get_in(jobs, ["queue_finalize", "facts"]) || %{}
    frozen = get_in(jobs, ["scheduler_freeze", "facts"]) || %{}
    scheduler = get_in(jobs, ["scheduler_finalize", "facts", "state"]) || "unknown"
    tuple = {start["initial_state"], start["resume_required"], queue["state"], queue["reason"]}

    guards =
      Map.take(start, ~w(cutover_started guard_established)) == %{"cutover_started" => "true", "guard_established" => "true"} and
        Map.take(frozen, ~w(freeze_started cron_disabled)) == %{"freeze_started" => "true", "cron_disabled" => "true"}

    valid =
      guards and scheduler == "configured" and
        tuple in [{"active", "true", "active", "resumed"}, {"paused", "false", "paused", "inherited_pause"}]

    %{valid: valid, inherited: queue["reason"] == "inherited_pause", queue: queue, scheduler: scheduler}
  end

  defp deployment_status(%{"status" => "completed", "conclusion" => "success"}, true), do: "success"
  defp deployment_status(%{"status" => "completed", "conclusion" => result}, _) when result in ~w(failure cancelled timed_out), do: "failure"
  defp deployment_status(_, _), do: "unconfirmed"

  defp freshness(report) do
    cond do
      is_nil(report["current_dev_sha"]) -> "unknown"
      report["current_dev_sha"] == report["sha"] -> "current"
      Settings.sha?(report["current_dev_sha"]) -> "stale"
      true -> "invalid"
    end
  end

  defp consistent?(report, status, cloud, freshness, blockers) do
    expected = %{"status" => if(blockers == [], do: "ready", else: "blocked"), "queue" => cloud.queue, "scheduler" => cloud.scheduler, "blockers" => blockers}

    report["deployment"] == status and report["freshness"] == freshness and report["environment"] == expected and
      (status != "success" or report["errors"] == [])
  end

  defp freshness_blockers("current"), do: []
  defp freshness_blockers("stale"), do: ["stale_dev_commit"]
  defp freshness_blockers(_), do: ["dev_head_unavailable"]

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
