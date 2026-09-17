defmodule SymphonyElixir.GitHubProjects.Delivery.Runs do
  @moduledoc "Workflow identity, complete attempt inventories, and independent deployment/CI results."

  alias SymphonyElixir.GitHubProjects.Delivery.{Client, Evidence, Policy, Settings}

  @statuses ~w(completed queued in_progress requested waiting pending)
  @conclusions ~w(success failure neutral cancelled skipped timed_out action_required stale startup_failure)
  @pointer ~w(id workflow_id event path head_sha head_branch status conclusion run_attempt created_at run_started_at updated_at)

  @spec inventory(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def inventory(client, path, repo) do
    with {:ok, workflow} <- Client.fetch(client, :workflow, [path]),
         true <- Settings.id?(workflow["id"]) and workflow["path"] == path and workflow["state"] == "active",
         {:ok, runs} <- Client.list(client, :runs, [workflow["id"]]),
         true <- Enum.all?(runs, &valid?(&1, workflow, repo)) do
      {:ok, %{workflow: workflow, runs: runs}}
    else
      {:error, _} = error -> error
      _ -> {:error, :workflow_identity_unconfirmed}
    end
  end

  @spec pointer(map()) :: map()
  def pointer(run), do: Map.take(run, @pointer ++ ~w(pull_requests repository head_repository referenced_workflows))

  @spec stamp(map()) :: term()
  def stamp(inventory), do: {inventory.workflow, inventory.runs |> Enum.map(&pointer/1) |> Enum.sort_by(& &1["id"])}

  @spec deployment(map(), map(), map(), String.t(), map()) :: {:ok, map(), [String.t()]} | {:error, term()}
  def deployment(client, inventory, policy, dev, repo) do
    runs = inventory.runs

    if runs == [] do
      {:ok, %{"result" => "unknown", "environment_ready" => false}, ["deployment_missing"]}
    else
      inspect_deployment(client, inventory, policy, dev, repo)
    end
  end

  @spec ci(map(), map(), map(), map() | nil, map() | nil, String.t()) ::
          {:ok, map() | nil, [String.t()]} | {:error, term()}
  def ci(_client, _inventory, _policy, nil, _cycle, _dev), do: {:ok, nil, []}

  def ci(_client, _inventory, _policy, %{"state" => "merged"}, _cycle, _dev),
    do: {:ok, %{"result" => "not_applicable_after_merge"}, []}

  def ci(client, inventory, policy, pr, cycle, dev) do
    runs = Enum.filter(inventory.runs, &ci_associated?(&1, pr))

    if runs == [] do
      {:ok, %{"result" => "unknown"}, ["pr_ci_missing"]}
    else
      inspect_ci(client, inventory, policy, runs, pr, cycle, dev)
    end
  end

  @spec verify_saved(map(), [map()], [map() | nil]) :: :ok | {:error, term()}
  def verify_saved(client, inventories, proofs) do
    listed = inventories |> Enum.flat_map(& &1.runs) |> Map.new(&{&1["id"], &1})
    ids = proofs |> Enum.reject(&is_nil/1) |> Enum.map(& &1["run_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Client.fetch(client, :run, [id]) do
        {:ok, run} ->
          saved_matches(run, listed[id])

        error ->
          {:halt, error}
      end
    end)
  end

  defp saved_matches(_, nil), do: {:halt, {:error, :saved_run_not_reconciled}}

  defp saved_matches(run, listed) do
    if pointer(run) == pointer(listed), do: {:cont, :ok}, else: {:halt, {:error, :saved_run_not_reconciled}}
  end

  defp valid?(run, workflow, repo) do
    Settings.id?(run["id"]) and Settings.id?(run["run_attempt"]) and run["workflow_id"] == workflow["id"] and
      run["path"] == workflow["path"] and Settings.sha?(run["head_sha"]) and
      run["repository"]["id"] == repo["id"] and run["repository"]["full_name"] == repo["full_name"] and
      run_times?(run)
  end

  defp run_times?(run) do
    run["status"] in @statuses and conclusion?(run) and
      Enum.all?(~w(created_at run_started_at updated_at), &is_integer(time(run[&1]))) and
      time(run["updated_at"]) >= time(run["run_started_at"]) and time(run["created_at"]) <= time(run["run_started_at"])
  end

  defp conclusion?(%{"status" => "completed", "conclusion" => result}), do: result in @conclusions
  defp conclusion?(run), do: is_nil(run["conclusion"])

  defp inspect_deployment(client, inventory, policy, dev, repo) do
    # A later attempt of an old run is ordered by execution time, never by run ID or creation time.
    candidate = Enum.max_by(inventory.runs, &time(&1["run_started_at"]))

    overlap = overlapping?(inventory.runs, candidate)

    fact = proof(candidate, client.settings.repo)

    cond do
      overlap ->
        {:ok, Map.put(fact, "result", "unknown"), ["deployment_attempts_overlap"]}

      candidate["head_branch"] != "dev" or candidate["event"] not in ~w(push workflow_dispatch) ->
        {:error, :unexpected_deployment_source}

      candidate["head_repository"]["id"] != repo["id"] ->
        {:error, :unexpected_deployment_repository}

      candidate["head_sha"] != dev ->
        {:ok, Map.put(fact, "result", "unknown"), ["deployment_not_current_dev"]}

      true ->
        deployment_result(client, candidate, policy, fact)
    end
  end

  defp overlapping?(runs, candidate) do
    Enum.any?(runs, fn run ->
      run["id"] != candidate["id"] and
        (run["status"] != "completed" or time(run["updated_at"]) >= time(candidate["run_started_at"]))
    end)
  end

  defp deployment_result(client, candidate, policy, fact) do
    cond do
      candidate["status"] != "completed" ->
        {:ok, Map.put(fact, "result", "pending"), ["deployment_pending"]}

      candidate["conclusion"] in ~w(failure cancelled timed_out startup_failure) ->
        {:ok, Map.put(fact, "result", "failure"), ["deployment_" <> candidate["conclusion"]]}

      candidate["conclusion"] != "success" ->
        {:ok, Map.put(fact, "result", "unknown"), ["deployment_not_successful"]}

      true ->
        evidence(client, candidate, policy, fact)
    end
  end

  defp evidence(client, run, policy, fact) do
    with :ok <- Policy.verify_sources(client, policy, run["head_sha"]),
         {:ok, jobs} <- Client.list(client, :jobs, [run["id"], run["run_attempt"]]),
         {:ok, artifacts} <- Client.list(client, :artifacts, [run["id"]]),
         [artifact] <- Enum.filter(artifacts, &(&1["name"] == "development-evidence-#{run["id"]}-#{run["run_attempt"]}")),
         true <- available?(artifact),
         {:ok, zip} <- Client.download(client, artifact["id"]),
         true <- byte_size(zip) == artifact["size_in_bytes"],
         {:ok, evidence} <- Evidence.verify(zip, artifact, run, jobs, policy, client.settings) do
      data = Map.new(evidence, fn {key, value} -> {Atom.to_string(key), value} end)
      result = Map.merge(fact, Map.put(data, "result", evidence.deployment))
      {:ok, result, evidence.blockers}
    else
      {:error, _} = error -> error
      _ -> {:error, :deployment_artifact_unavailable}
    end
  end

  defp available?(artifact) do
    is_integer(time(artifact["expires_at"])) and time(artifact["expires_at"]) > System.system_time(:millisecond) and
      artifact["expired"] == false
  end

  defp ci_associated?(run, pr) do
    run["event"] == "pull_request" and is_list(run["pull_requests"]) and
      (Enum.any?(run["pull_requests"], &(&1["id"] == pr["id"] and &1["number"] == pr["number"])) or
         Enum.any?(run["referenced_workflows"] || [], &(&1["ref"] == "refs/pull/#{pr["number"]}/merge")))
  end

  defp inspect_ci(client, inventory, policy, runs, pr, cycle, dev) do
    current =
      Enum.filter(runs, fn run ->
        run["head_sha"] == pr["head_sha"] and run["head_branch"] == pr["branch"] and
          run["head_repository"]["id"] == pr["repo_id"]
      end)

    if current == [] do
      {:ok, %{"result" => "unknown"}, ["pr_ci_not_current"]}
    else
      run = Enum.max_by(current, &time(&1["run_started_at"]))

      inspect_ci_run(client, inventory, policy, run, pr, cycle, dev)
    end
  end

  defp inspect_ci_run(client, inventory, policy, run, pr, cycle, dev) do
    with {:ok, tested_sha} <- tested_commit(client, run, pr, dev),
         :ok <- Policy.verify_sources(client, policy, tested_sha),
         {:ok, result} <- ci_result(client, run, policy.pr_jobs),
         {:ok, failure_kind} <- failure_kind(client, run, policy.pr_jobs),
         {:ok, origin} <- origin(cycle, run, pr["head_sha"]) do
      fact =
        proof(run, client.settings.repo)
        |> Map.merge(origin)
        |> Map.merge(%{
          "workflow_id" => inventory.workflow["id"],
          "result" => result,
          "head_sha" => pr["head_sha"],
          "base_sha" => dev,
          "tested_sha" => tested_sha,
          "failure_kind" => failure_kind
        })

      reasons = if result == "success", do: [], else: ["pr_ci_" <> result]
      {:ok, fact, reasons}
    end
  end

  defp tested_commit(client, run, pr, dev) do
    with true <- is_list(run["referenced_workflows"]),
         [reference] <- run["referenced_workflows"],
         sha = reference["sha"],
         true <- Settings.sha?(sha) and sha == pr["test_merge_sha"],
         true <-
           reference["ref"] == "refs/pull/#{pr["number"]}/merge" and
             reference["path"] == client.settings.repo <> "/" <> client.settings.policy["verify_workflow"] <> "@" <> sha,
         {:ok, commit} <- Client.fetch(client, :commit, [sha]),
         true <- commit["sha"] == sha and Enum.map(commit["parents"], & &1["sha"]) == [dev, pr["head_sha"]] do
      {:ok, sha}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_merge_commit_unconfirmed}
    end
  end

  defp ci_result(client, run, mapping) do
    cond do
      run["status"] != "completed" ->
        {:ok, "pending"}

      run["conclusion"] == "cancelled" ->
        {:ok, "cancelled"}

      run["conclusion"] in ~w(failure timed_out startup_failure) ->
        {:ok, "failure"}

      run["conclusion"] != "success" ->
        {:ok, "unknown"}

      true ->
        verify_ci_jobs(client, run, mapping)
    end
  end

  defp failure_kind(client, %{"conclusion" => "failure"} = run, mapping) do
    with {:ok, jobs} <- Client.list(client, :jobs, [run["id"], run["run_attempt"]]),
         {:ok, bound} <- Evidence.bind_jobs(jobs, run, mapping) do
      names = mapping["verify"].steps |> Enum.filter(fn {id, _} -> String.starts_with?(id, "check_") and id != "check_ci_gate" end) |> Enum.map(&elem(&1, 1))
      steps = bound["verify"]["steps"] || []
      first = Enum.find(steps, &(&1["conclusion"] not in ["success", "skipped"]))
      code = is_map(first) and first["status"] == "completed" and first["conclusion"] == "failure" and first["name"] in names
      {:ok, if(code, do: "verification", else: "unknown")}
    end
  end

  defp failure_kind(_, _, _), do: {:ok, "unknown"}

  defp verify_ci_jobs(client, run, mapping) do
    with {:ok, jobs} <- Client.list(client, :jobs, [run["id"], run["run_attempt"]]),
         {:ok, bound} <- Evidence.bind_jobs(jobs, run, mapping) do
      success = Enum.all?(mapping, fn {name, job} -> Evidence.successful_job?(bound[name], job.required) end)
      {:ok, if(success, do: "success", else: "unknown")}
    end
  end

  defp origin(cycle, run, sha) do
    entries = if cycle, do: Map.values(cycle["budget"]["ci"]), else: []
    matches = Enum.filter(entries, &(&1["run_id"] == run["id"] and &1["run_attempt"] == run["run_attempt"]))

    case matches do
      [%{"sha" => ^sha, "reservation_id" => id}] -> {:ok, %{"origin" => "reserved", "reservation_id" => id}}
      [] -> unbound_origin(entries, sha, run["run_attempt"])
      _ -> {:error, :ambiguous_ci_reservation}
    end
  end

  defp unbound_origin(entries, sha, 1) do
    case Enum.filter(entries, &(&1["run_id"] == nil and &1["sha"] == sha and &1["result"] in ~w(reserved unknown))) do
      [%{"reservation_id" => id}] -> {:ok, %{"origin" => "reserved", "reservation_id" => id}}
      [] -> {:ok, %{"origin" => "external", "reservation_id" => nil}}
      _ -> {:error, :ambiguous_ci_reservation}
    end
  end

  defp unbound_origin(_, _, _), do: {:ok, %{"origin" => "external", "reservation_id" => nil}}

  defp proof(run, repo) do
    %{
      "sha" => run["head_sha"],
      "workflow_id" => run["workflow_id"],
      "run_id" => run["id"],
      "run_attempt" => run["run_attempt"],
      "status" => run["status"],
      "conclusion" => run["conclusion"],
      "environment_ready" => false,
      "url" => "https://github.com/#{repo}/actions/runs/#{run["id"]}/attempts/#{run["run_attempt"]}"
    }
  end

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> DateTime.to_unix(date, :millisecond)
      _ -> nil
    end
  end

  defp time(_), do: nil
end
