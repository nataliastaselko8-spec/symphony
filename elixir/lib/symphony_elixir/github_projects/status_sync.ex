defmodule SymphonyElixir.GitHubProjects.StatusSync do
  @moduledoc "One bounded status attempt: fresh identity/evidence, persisted send fence, mutation, readback."

  alias SymphonyElixir.Config
  alias SymphonyElixir.DeliveryGate.Command
  alias SymphonyElixir.DeliveryGate.StatusSync, as: Journal
  alias SymphonyElixir.GitHubProjects.{Client, Delivery, WriteClient}
  alias SymphonyElixir.GitHubProjects.Delivery.Observation

  @spec step(Config.Schema.t(), map(), map(), (atom() -> term()), keyword()) :: map()
  def step(config, context, op, authorize, opts) do
    with {:ok, settings} <- Config.delivery_observer_settings(config),
         true <- String.downcase(settings.repo) == String.downcase(op["repo"]),
         target when is_binary(target) <- settings.project.states[op["role"]] do
      attempt(config, settings, context, op, target, authorize, opts)
    else
      _ -> outcome("failed", nil, "status_configuration_changed")
    end
  end

  defp attempt(config, settings, context, op, target, authorize, opts) do
    current = Journal.current?(context.state, op)

    cond do
      not current and not op["sent"] ->
        outcome("superseded", nil, nil)

      op["checks"] >= 10 ->
        outcome("failed", op["observed"], "status_reconciliation_exhausted")

      true ->
        case scope(settings, op, opts) do
          {:ok, scope} -> reconcile(config, settings, context, op, target, scope, authorize, opts)
          {:error, reason} -> failure(reason, op["sent"])
        end
    end
  end

  defp reconcile(config, settings, context, op, target, scope, authorize, opts) do
    observed = scope.row["state"]

    cond do
      observed == target -> confirm_existing(config, settings, context, op, target, opts)
      observed != op["from"] -> outcome("conflict", observed, "status_manually_changed")
      op["sent"] -> outcome("unknown", observed, "status_write_unknown", 30_000)
      op["attempts"] >= 3 -> outcome("failed", observed, "status_retry_exhausted")
      true -> send_status(config, settings, context, op, target, scope, authorize, opts)
    end
  end

  defp send_status(config, settings, context, op, target, scope, authorize, opts) do
    cycle = Journal.cycle(context.state, op)
    client = WriteClient.new(settings, cycle, opts)

    with :ok <- evidence(config, settings, context, op, client, opts),
         {:ok, fresh} <- scope(settings, op, opts),
         true <- fresh.row["state"] == scope.row["state"],
         :ok <- authorize.(:sent) do
      case WriteClient.sync_status(client, fresh, op["role"]) do
        {:ok, _} -> readback(settings, op, target, opts)
        {:error, {:publication_limited, _} = reason} -> failure(reason, false)
        {:error, reason} -> failure(reason, true)
      end
    else
      false -> outcome("conflict", nil, "status_manually_changed")
      {:error, reason} -> failure(reason, op["sent"])
    end
  end

  defp readback(settings, op, target, opts) do
    case scope(settings, op, opts) do
      {:ok, after_read} ->
        if after_read.row["state"] == target,
          do: outcome("confirmed", target, nil),
          else: outcome("conflict", after_read.row["state"], "status_readback_changed")

      _ ->
        outcome("unknown", nil, "status_readback_unconfirmed", 30_000)
    end
  end

  defp confirm_existing(config, settings, context, op, target, opts) do
    client = WriteClient.new(settings, Journal.cycle(context.state, op), opts)

    result = if Journal.current?(context.state, op), do: evidence(config, settings, context, op, client, opts), else: :ok

    case result do
      :ok -> outcome("confirmed", target, nil)
      {:error, reason} -> %{failure(reason, op["sent"]) | observed: target}
    end
  end

  defp scope(settings, op, opts) do
    reader = Keyword.get(opts, :project_reader, &Client.inspect/2)

    with true <- settings.project.item_ids == nil or op["task"]["item_id"] in settings.project.item_ids,
         {:ok, report} <- reader.(settings.tracker, opts),
         true <- report["project"]["id"] != nil and report["project"]["repo"] == settings.repo,
         [row] <- Enum.filter(report["items"], &(&1["item_id"] == op["task"]["item_id"])),
         true <- row["in_scope"] == true and row["archived"] == false and row["native_ref"]["issue_id"] == op["task"]["issue_id"] and row["native_ref"]["repo"] == settings.repo,
         true <- row["issue_state"] == "OPEN" or (row["issue_state"] == "CLOSED" and post_merge?(op)),
         true <- is_binary(row["state"]),
         true <- working_allowed?(op, row, report["schema"]) do
      {:ok, %{row: row, project: report["project"], schema: report["schema"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :status_scope_changed}
    end
  end

  defp post_merge?(op), do: op["role"] in ~w(dev_validation production_ready) or (op["role"] == "blocked" and is_binary(get_in(op, ["evidence", "work", "merge_sha"])))

  defp working_allowed?(%{"role" => "working", "sent" => false}, row, schema) do
    row["native_ref"]["agent_allowed_option_id"] == schema["agent_allowed_option_id"] and
      Enum.all?(row["reasons"], &(&1 == "inactive_status"))
  end

  defp working_allowed?(_, _, _), do: true

  defp evidence(_, _, _, %{"role" => "blocked", "evidence" => %{"work" => %{"merge_sha" => nil}}}, _, _), do: :ok

  defp evidence(_, _, context, %{"role" => "working"} = op, client, _) do
    with {:ok, sha} <- WriteClient.dev(client),
         true <- sha == Journal.cycle(context.state, op)["work"]["base_sha"],
         do: :ok,
         else: (
           false -> {:error, :status_evidence_changed}
           error -> error
         )
  end

  defp evidence(config, settings, context, op, client, opts) do
    cycle = Journal.cycle(context.state, op)
    retained = put_in(context, [:state, "cycle"], cycle)
    observer = Keyword.get(opts, :observer, &Delivery.observe/2)

    with {:ok, obs} <- observer.(config, Keyword.put(opts, :context, retained)),
         :ok <- Observation.validate(obs, settings, retained),
         true <- proof?(op["role"], cycle, obs.facts),
         :ok <- linkage(op["role"], client),
         do: :ok,
         else: (
           false -> {:error, :status_evidence_changed}
           {:error, _} = error -> error
         )
  end

  defp linkage(role, client) when role in ~w(handoff review) do
    with {:ok, issue} <- WriteClient.issue(client),
         {:ok, [pr]} <- WriteClient.pulls(client),
         true <- pr["number"] == client.cycle["work"]["pr_number"] and pr["node_id"] in issue.links,
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> {:error, :status_linkage_changed}
         )
  end

  defp linkage(_, _), do: :ok

  defp proof?(role, cycle, facts) when role in ~w(handoff review) do
    pr = facts["pr"] || %{}
    ci = facts["ci"] || %{}

    pr["number"] == cycle["work"]["pr_number"] and pr["head_sha"] == cycle["work"]["head_sha"] and
      pr["state"] == "open" and ci["result"] == "success" and facts["dev_sha"] == cycle["work"]["base_sha"] and
      ci["head_sha"] == cycle["work"]["head_sha"] and ci["base_sha"] == facts["dev_sha"]
  end

  defp proof?("dev_validation", cycle, facts) do
    pr = facts["pr"] || %{}
    pr["state"] == "merged" and pr["number"] == cycle["work"]["pr_number"] and pr["merge_sha"] == cycle["work"]["merge_sha"] and pr["ancestry"] == "included"
  end

  defp proof?("blocked", cycle, facts), do: proof?("dev_validation", cycle, facts)

  defp proof?("production_ready", cycle, facts) do
    deployment = facts["deployment"] || %{}

    proof?("dev_validation", cycle, facts) and cycle["validation"]["passed"] == true and
      deployment["result"] == "success" and deployment["environment_ready"] == true and
      facts["dev_sha"] == cycle["validation"]["sha"] and Command.proof(deployment) == Command.proof(cycle["validation"])
  end

  defp failure({:publication_limited, seconds}, sent), do: outcome(if(sent, do: "unknown", else: "retry"), nil, "status_rate_limited", seconds * 1_000)
  defp failure({:github_projects_http, _, seconds}, sent) when is_integer(seconds), do: outcome(if(sent, do: "unknown", else: "retry"), nil, "status_read_limited", seconds * 1_000)
  defp failure(reason, _) when reason in [:status_permission_denied, :status_write_refused, :status_scope_changed], do: outcome("failed", nil, Atom.to_string(reason))
  defp failure(reason, _) when reason in [:status_evidence_changed, :status_linkage_changed, :observation_scope_changed, :stale_observation], do: outcome("conflict", nil, Atom.to_string(reason))
  defp failure({:github_delivery_limited, seconds}, sent), do: outcome(if(sent, do: "unknown", else: "retry"), nil, "status_evidence_limited", seconds * 1_000)
  defp failure(_, sent), do: outcome(if(sent, do: "unknown", else: "retry"), nil, "status_request_unconfirmed", 30_000)
  defp outcome(status, observed, error, delay \\ 0), do: %{status: status, observed: observed, error: error, delay_ms: delay}
end
