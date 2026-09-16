defmodule SymphonyElixir.GitHubProjects.Delivery do
  @moduledoc "Finite read-only observer. It never starts the application, a worker, or a delivery store."

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubProjects.Delivery.{Client, Observation, Ownership, Policy, Runs, Settings}

  @spec observe(Config.Schema.t(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def observe(config, opts \\ []) do
    with {:ok, settings} <- Config.delivery_observer_settings(config),
         {:ok, context} <- Observation.context(Keyword.get(opts, :context)) do
      deadline = min(max(Keyword.get(opts, :deadline_ms, 300_000), 1), 300_000)
      client = Client.new(settings, Keyword.put(opts, :deadline_ms, deadline))
      task = Task.async(fn -> safely_observe(client, context) end)

      case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
        {:ok, observation} -> {:ok, observation}
        _ -> {:ok, Observation.failure(settings, context, :observation_deadline)}
      end
    end
  end

  defp safely_observe(client, context) do
    case gather(client, context) do
      {:ok, facts, reasons} -> Observation.new(client.settings, context, facts, reasons)
      {:error, reason} -> Observation.failure(client.settings, context, reason)
    end
  rescue
    _ -> Observation.failure(client.settings, context, :invalid_delivery_response)
  catch
    _, _ -> Observation.failure(client.settings, context, :delivery_read_failed)
  end

  defp gather(client, context) do
    with {:ok, repo} <- repository(client),
         {:ok, policy} <- Policy.load(client),
         {:ok, before} <- pointers(client, context, repo),
         {:ok, deployment, deployment_reasons} <- Runs.deployment(client, before.deployment, policy, before.dev, repo),
         {:ok, ci, ci_reasons} <- Runs.ci(client, before.ci, policy, before.ownership["pr"], context.state["cycle"], before.dev),
         :ok <- Runs.verify_saved(client, [before.deployment, before.ci], saved_proofs(context)),
         {:ok, after_read} <- pointers(client, context, repo),
         true <- stamp(before) == stamp(after_read),
         true <- client.now.() <= client.deadline do
      facts =
        Map.merge(before.ownership, %{
          "repo" => client.settings.repo,
          "repo_id" => repo["id"],
          "dev_sha" => before.dev,
          "ci" => ci,
          "deployment" => deployment,
          "readiness_source" => "deployment_evidence",
          "readiness_is_live" => false,
          "deployment_runs_observed" => length(before.deployment.runs),
          "policy_commit" => client.settings.policy["contract_commit"],
          "policy_hashes" => policy.hashes
        })

      reasons = before.reasons ++ deployment_reasons ++ ci_reasons ++ ["manual_dev_validation_required"]
      {:ok, facts, reasons}
    else
      {:error, _} = error -> error
      false -> {:error, :observation_changed}
    end
  end

  defp repository(client) do
    with {:ok, repo} <- Client.fetch(client, :repo),
         true <-
           Settings.id?(repo["id"]) and is_binary(repo["node_id"]) and repo["node_id"] != "" and
             repo["full_name"] == client.settings.repo do
      {:ok, repo}
    else
      {:error, _} = error -> error
      _ -> {:error, :repository_identity_unconfirmed}
    end
  end

  defp pointers(client, context, repo) do
    with {:ok, dev} <- Ownership.ref(client),
         {:ok, project} <- Ownership.project(client, repo),
         {:ok, pulls} <- Client.list(client, :pulls),
         {:ok, ownership, reasons} <- Ownership.observe(client, context, project, pulls, repo, dev),
         {:ok, deployment} <- Runs.inventory(client, client.settings.policy["deployment_workflow"], repo),
         {:ok, ci} <- Runs.inventory(client, client.settings.policy["pr_workflow"], repo) do
      {:ok, %{dev: dev, ownership: ownership, reasons: reasons, pulls: pulls, deployment: deployment, ci: ci}}
    end
  end

  defp stamp(value), do: {value.dev, value.ownership, value.reasons, Ownership.pull_stamp(value.pulls), Runs.stamp(value.deployment), Runs.stamp(value.ci)}

  defp saved_proofs(context) do
    cycle = context.state["cycle"]
    cycles = if cycle, do: Enum.reject([cycle, cycle["suspended"]], &is_nil/1), else: []

    [
      context.state["baseline"]
      | Enum.flat_map(cycles, fn value ->
          [value["deployment"] | Map.values(value["budget"]["ci"])]
        end)
    ]
  end
end
