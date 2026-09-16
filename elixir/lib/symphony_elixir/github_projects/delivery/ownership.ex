defmodule SymphonyElixir.GitHubProjects.Delivery.Ownership do
  @moduledoc "Observe retained ownership, including cancellation and a suspended recovery owner."

  alias SymphonyElixir.GitHubProjects.Client, as: Projects
  alias SymphonyElixir.GitHubProjects.Delivery.{Client, Settings}

  @spec project(map(), map()) :: {:ok, map()} | {:error, term()}
  def project(client, repo) do
    tracker = %{client.settings.tracker | provider: Map.delete(client.settings.tracker.provider, "item_ids")}
    reader = Keyword.get(client.opts, :project_reader, &Projects.inspect/2)

    with {:ok, report} <- reader.(tracker, client.opts),
         true <- report["project"]["repository_id"] == repo["node_id"],
         true <- is_list(report["items"]) do
      rows = Enum.map(report["items"], &project_row/1)
      {:ok, %{"project_id" => report["project"]["id"], "items" => Enum.sort_by(rows, & &1["item_id"])}}
    else
      {:error, _} = error -> error
      _ -> {:error, :project_repository_mismatch}
    end
  end

  defp project_row(row) do
    row
    |> Map.take(~w(item_id state archived issue_state))
    |> Map.put(
      "native_ref",
      Map.take(row["native_ref"], ~w(issue_id repo status_option_id agent_allowed_option_id))
    )
  end

  @spec observe(map(), map(), map(), list(), map(), String.t()) :: {:ok, map(), [String.t()]} | {:error, term()}
  def observe(client, context, project, open_prs, repo, dev) do
    cycle = context.state["cycle"]
    owners = if cycle, do: Enum.reject([cycle, cycle["suspended"]], &is_nil/1), else: []

    with :ok <- validate_pulls(open_prs, repo),
         {:ok, bindings} <- bind_owners(client, owners, project, open_prs, repo, dev) do
      task_ids = Enum.map(owners, & &1["task"]["item_id"])
      blockers = blocking_items(project["items"], task_ids, client.settings)
      reasons = Enum.flat_map(bindings, & &1.reasons) ++ blockers ++ cycle_reasons(cycle, bindings)
      current = List.first(bindings)

      facts = %{
        "owner" => if(cycle, do: cycle["owner"]),
        "task" => if(cycle, do: cycle["task"]),
        "phase" => if(cycle, do: cycle["phase"]),
        "cancellation_pending" => cycle != nil and cycle["cancellation"] != nil,
        "recovery_active" => cycle != nil and cycle["recovery"] != nil,
        "pr" => if(current, do: current.pr),
        "suspended_pr" => if(length(bindings) > 1, do: Enum.at(bindings, 1).pr),
        "open_pr_numbers" => Enum.map(open_prs, & &1["number"]) |> Enum.sort(),
        "project" => project
      }

      {:ok, facts, reasons}
    end
  end

  defp validate_pulls(pulls, repo) do
    valid =
      Enum.all?(pulls, fn pr ->
        Settings.id?(pr["id"]) and Settings.id?(pr["number"]) and pr["state"] == "open" and
          pr["base"]["ref"] == "dev" and pr["base"]["repo"]["id"] == repo["id"] and
          is_binary(pr["head"]["ref"]) and pr["head"]["ref"] != ""
      end)

    if valid, do: :ok, else: {:error, :open_pr_inventory_unconfirmed}
  end

  @spec pull_stamp(list()) :: list()
  def pull_stamp(pulls) do
    pulls
    |> Enum.map(&Map.take(&1, ~w(id number state draft merged merged_at merge_commit_sha head base updated_at)))
    |> Enum.sort_by(& &1["id"])
  end

  @spec ref(map()) :: {:ok, String.t()} | {:error, term()}
  def ref(client) do
    with {:ok, %{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => sha}}} <- Client.fetch(client, :ref),
         true <- Settings.sha?(sha) do
      {:ok, sha}
    else
      {:error, _} = error -> error
      _ -> {:error, :dev_head_unconfirmed}
    end
  end

  defp bind_owners(client, owners, project, open_prs, repo, dev) do
    Enum.reduce_while(owners, {:ok, []}, fn owner, {:ok, acc} ->
      case pull(client, owner, open_prs, repo, dev) do
        {:ok, pr, reasons} ->
          reasons = reasons ++ item_reasons(project["items"], owner["task"])
          {:cont, {:ok, acc ++ [%{pr: pr, reasons: reasons}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp pull(client, cycle, open_prs, repo, dev) do
    work = cycle["work"]
    number = work["pr_number"]
    related = Enum.filter(open_prs, &(get_in(&1, ["head", "ref"]) == work["branch"]))

    cond do
      Enum.any?(related, &(&1["number"] != number)) ->
        {:ok, nil, ["pr_association_requires_operator"]}

      is_nil(number) ->
        {:ok, nil, ["task_pr_not_bound"]}

      true ->
        with {:ok, pr} <- Client.fetch(client, :pull, [number]),
             true <- pr_identity?(pr, number, repo, work),
             {:ok, ancestry} <- ancestry(client, pr, work, dev) do
          fact = %{
            "id" => pr["id"],
            "number" => number,
            "repo_id" => repo["id"],
            "branch" => pr["head"]["ref"],
            "head_sha" => pr["head"]["sha"],
            "base_sha" => pr["base"]["sha"],
            "base_ref" => "dev",
            "merge_sha" => if(pr["merged"], do: pr["merge_commit_sha"]),
            "ancestry" => ancestry,
            "test_merge_sha" => if(not pr["merged"], do: pr["merge_commit_sha"]),
            "state" => pr_state(pr),
            "draft" => pr["draft"],
            "updated_at" => pr["updated_at"]
          }

          {:ok, fact, pr_reasons(fact, work)}
        else
          {:error, _} = error -> error
          _ -> {:error, :pr_identity_unconfirmed}
        end
    end
  end

  defp pr_identity?(pr, number, repo, work) do
    expected = %{"number" => number}

    shape =
      Map.take(pr, ["number"]) == expected and Settings.id?(pr["id"]) and is_boolean(pr["merged"]) and
        is_boolean(pr["draft"]) and pr["state"] in ~w(open closed)

    shape and pr_refs?(pr, repo, work)
  end

  defp pr_refs?(pr, repo, work) do
    pr["base"]["repo"]["id"] == repo["id"] and pr["head"]["repo"]["id"] == repo["id"] and
      pr["base"]["ref"] == "dev" and pr["head"]["ref"] == work["branch"] and Settings.sha?(pr["head"]["sha"])
  end

  defp ancestry(client, %{"merged" => true} = pr, work, dev) do
    merge = pr["merge_commit_sha"]

    cond do
      not Settings.sha?(merge) ->
        {:error, :merge_sha_unconfirmed}

      work["merge_sha"] not in [nil, merge] ->
        {:ok, "changed"}

      merge == dev ->
        {:ok, "included"}

      true ->
        with {:ok, comparison} <- Client.fetch(client, :compare, [merge, dev]),
             true <- comparison["base_commit"]["sha"] == merge do
          ancestry_result(comparison, merge)
        else
          {:error, _} = error -> error
          _ -> {:error, :merge_ancestry_unconfirmed}
        end
    end
  end

  defp ancestry(_, _, %{"merge_sha" => sha}, _) when is_binary(sha), do: {:ok, "changed"}
  defp ancestry(_, _, _, _), do: {:ok, "not_merged"}

  defp ancestry_result(comparison, merge) do
    if comparison["status"] in ~w(ahead identical) and comparison["merge_base_commit"]["sha"] == merge, do: {:ok, "included"}, else: {:ok, "missing"}
  end

  defp pr_state(%{"merged" => true}), do: "merged"
  defp pr_state(%{"state" => "closed"}), do: "closed"
  defp pr_state(%{"draft" => true}), do: "draft"
  defp pr_state(_), do: "open"

  defp pr_reasons(pr, work) do
    reasons =
      case pr["state"] do
        "closed" -> ["pr_closed_without_merge"]
        "draft" -> ["pr_draft"]
        "open" -> ["awaiting_review_or_merge"]
        "merged" -> []
      end

    reasons = if work["head_sha"] in [nil, pr["head_sha"]], do: reasons, else: reasons ++ ["pr_head_changed"]
    if pr["ancestry"] in ~w(missing changed), do: reasons ++ ["merge_ancestry_" <> pr["ancestry"]], else: reasons
  end

  defp item_reasons(rows, task) do
    case Enum.filter(rows, &(&1["item_id"] == task["item_id"])) do
      [row] ->
        cond do
          row["native_ref"]["issue_id"] != task["issue_id"] -> ["owner_issue_changed"]
          row["archived"] -> ["owner_item_archived"]
          row["issue_state"] != "OPEN" -> ["owner_issue_closed"]
          row["state"] == "Done" -> ["owner_item_done_requires_reconciliation"]
          true -> []
        end

      _ ->
        ["owner_item_missing"]
    end
  end

  defp blocking_items(rows, ids, settings) do
    states = Map.take(settings.project.states, ~w(working blocked handoff)) |> Map.values()

    Enum.flat_map(rows, fn row ->
      repo = row["native_ref"]["repo"]

      cond do
        row["item_id"] in ids -> []
        repo != nil and String.downcase(repo) != String.downcase(settings.repo) -> []
        is_nil(row["state"]) or is_nil(repo) -> ["project_item_unconfirmed"]
        row["state"] in (states ++ ["Human review", "Dev validation"]) -> ["unowned_delivery_item"]
        true -> []
      end
    end)
  end

  defp cycle_reasons(nil, _), do: []

  defp cycle_reasons(cycle, bindings) do
    reasons = if cycle["cancellation"], do: ["operator_cancel_pending"], else: []
    reasons = if cycle["recovery"], do: reasons ++ ["recovery_owner_retained"], else: reasons
    suspended = Enum.at(bindings, 1)
    if suspended && suspended.pr && suspended.pr["state"] == "merged" && cycle["suspended"]["work"]["merge_sha"] == nil, do: reasons ++ ["primary_merged_during_recovery"], else: reasons
  end
end
