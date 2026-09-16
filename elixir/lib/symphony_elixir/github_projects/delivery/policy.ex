defmodule SymphonyElixir.GitHubProjects.Delivery.Policy do
  @moduledoc "Approved immutable workflow sources and unambiguous job/step names. No code is evaluated."

  alias SymphonyElixir.GitHubProjects.Delivery.{Client, JSON, Settings}

  @spec load(map()) :: {:ok, map()} | {:error, term()}
  def load(client) do
    settings = client.settings

    with {:ok, sources} <- read_sources(client, settings.policy["contract_commit"]) do
      parse(sources, settings)
    end
  end

  @spec verify_sources(map(), map(), String.t()) :: :ok | {:error, term()}
  def verify_sources(client, policy, sha) do
    if sha == client.settings.policy["contract_commit"] do
      :ok
    else
      with {:ok, sources} <- read_sources(client, sha) do
        compare_sources(sources, policy)
      end
    end
  end

  defp compare_sources(sources, policy) do
    if hashes(sources) == policy.hashes, do: :ok, else: {:error, :workflow_policy_changed}
  end

  @spec parse(map(), map()) :: {:ok, map()} | {:error, :invalid_delivery_policy}
  def parse(sources, settings) do
    p = settings.policy

    with true <- hash(sources[p["contract_path"]]) == p["contract_sha256"],
         {:ok, spec} <- JSON.decode(sources[p["contract_path"]]),
         true <- spec["schema_version"] === 1 and spec["repository"] == settings.repo,
         true <- spec["workflow"] == p["deployment_workflow"],
         true <- valid_jobs?(spec["jobs"]),
         {:ok, deployment} <- YamlElixir.read_from_string(sources[p["deployment_workflow"]]),
         {:ok, verify} <- YamlElixir.read_from_string(sources[p["verify_workflow"]]),
         {:ok, pr} <- YamlElixir.read_from_string(sources[p["pr_workflow"]]),
         true <- is_map(deployment) and is_map(verify) and is_map(pr),
         {:ok, jobs} <- deployment_jobs(deployment, verify, spec, p),
         {:ok, pr_jobs} <- pr_jobs(pr, verify, spec, p) do
      {:ok, %{spec: spec, jobs: jobs, pr_jobs: pr_jobs, hashes: hashes(sources)}}
    else
      _ -> {:error, :invalid_delivery_policy}
    end
  rescue
    _ -> {:error, :invalid_delivery_policy}
  end

  @spec hash(binary()) :: String.t()
  def hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp read_sources(client, sha) do
    Enum.reduce_while(Settings.paths(client.settings.policy), {:ok, %{}}, fn path, {:ok, acc} ->
      case Client.content(client, path, sha) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, path, bytes)}}
        error -> {:halt, error}
      end
    end)
  end

  defp hashes(sources), do: Map.new(sources, fn {path, bytes} -> {path, hash(bytes)} end)

  defp valid_jobs?(jobs) when is_map(jobs) and map_size(jobs) > 0 do
    Enum.all?(jobs, fn {name, job} ->
      job_shape?(name, job) and
        Enum.all?(job["required_steps"], &(&1 in job["observed_steps"])) and
        Enum.all?(job["dependencies"], &Map.has_key?(jobs, &1))
    end) and Enum.all?(~w(verify scheduler_freeze queue_pause scheduler_finalize queue_finalize), &Map.has_key?(jobs, &1))
  end

  defp valid_jobs?(_), do: false

  defp job_shape?(name, job) do
    is_binary(name) and Regex.match?(~r/\A[a-z_]+\z/, name) and is_map(job) and
      job["kind"] in ["normal", "finalizer"] and string_list?(job["required_steps"]) and
      string_list?(job["observed_steps"]) and string_list?(job["dependencies"])
  end

  defp deployment_jobs(workflow, verify, spec, p) do
    mapping =
      Map.new(spec["jobs"], fn {name, contract} ->
        job = Map.fetch!(workflow["jobs"], name)
        {name, bind_job(name, job, verify, contract, p)}
      end)

    evidence = Map.fetch!(workflow["jobs"], "deployment_evidence")
    collector = %{name: evidence["name"], steps: step_names(evidence["steps"]), required: Enum.map(evidence["steps"], &step_name/1)}
    mapping = Map.put(mapping, "deployment_evidence", collector)
    if unique_names?(mapping), do: {:ok, mapping}, else: :error
  end

  defp bind_job("verify", job, verify, contract, p) do
    true = job["uses"] == "./" <> p["verify_workflow"]
    child = Map.fetch!(verify["jobs"], "verify")
    true = map_size(verify["jobs"]) == 1
    mapped(job["name"] || "verify", child, contract, true)
  end

  defp bind_job(name, job, _verify, contract, p) do
    environment =
      case job["environment"] do
        %{"name" => value} -> value
        value -> value
      end

    true = is_binary(environment) and Regex.match?(~r/\A[a-z][a-z0-9-]*\z/, environment)
    true = environment == p["environment"] or String.starts_with?(environment, p["environment"] <> "-")
    Map.put(mapped(job["name"] || name, job, contract, false), :environment, environment)
  end

  defp mapped(prefix, job, contract, reusable) do
    names = step_names(job["steps"])
    true = Enum.all?(contract["observed_steps"], &Map.has_key?(names, &1))
    name = if reusable, do: prefix <> " / " <> (job["name"] || "verify"), else: prefix
    %{name: name, steps: names, required: Enum.map(contract["required_steps"], &Map.fetch!(names, &1))}
  end

  defp pr_jobs(workflow, verify, spec, p) do
    check = bind_job("verify", Map.fetch!(workflow["jobs"], "verify"), verify, spec["jobs"]["verify"], p)
    result = Map.fetch!(workflow["jobs"], "result")
    result = %{name: result["name"] || "result", steps: step_names(result["steps"]), required: Enum.map(result["steps"], &step_name/1)}
    mapping = %{"verify" => check, "result" => result}
    if unique_names?(mapping), do: {:ok, mapping}, else: :error
  end

  defp step_names(steps) do
    true = is_list(steps) and steps != []
    names = Enum.map(steps, &step_name/1)
    true = string_list?(names)
    true = string_list?(Enum.map(steps, &(&1["id"] || step_name(&1))))
    Map.new(steps, fn step -> {step["id"] || step_name(step), step_name(step)} end)
  end

  defp step_name(step), do: step["name"] || step["id"]
  defp unique_names?(jobs), do: jobs |> Map.values() |> Enum.map(& &1.name) |> string_list?()

  defp string_list?(values) when is_list(values),
    do: length(Enum.uniq(values)) == length(values) and Enum.all?(values, &(is_binary(&1) and &1 != "" and not String.contains?(&1, "${{")))

  defp string_list?(_), do: false
end
