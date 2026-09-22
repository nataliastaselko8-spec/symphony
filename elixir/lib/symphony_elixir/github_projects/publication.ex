defmodule SymphonyElixir.GitHubProjects.Publication do
  @moduledoc "One outbox step. Intent is persisted by the runtime before any remote write."
  alias SymphonyElixir.DeliveryGate.{Budget, Effects}
  alias SymphonyElixir.GitHubProjects.{GitPublisher, WriteClient}

  @type result :: {:ok, String.t(), map()} | {:error, term()}
  @spec step(map(), map(), map(), (String.t(), map() -> term()), keyword()) :: result()
  def step(settings, cycle, effect, authorize, opts) do
    client = WriteClient.new(settings, cycle, opts)
    step = Effects.next(effect) || "finalize"
    states = [settings.project.states["ready"], settings.project.states["working"]]
    states = if step in ~w(status finalize) or (step == "link" and sent?(effect, step)), do: states ++ [settings.project.states["handoff"]], else: states
    states = if effect["kind"] == "block", do: states ++ [settings.project.states["blocked"]], else: states

    with {:ok, scope} <- WriteClient.scope(client, states),
         {:ok, dev} <- WriteClient.dev(client),
         true <- dev == Keyword.fetch!(opts, :base_sha),
         {:ok, result} <- perform(client, scope, effect, step, authorize, opts) do
      {:ok, step, result}
    else
      false -> {:error, :publication_base_changed}
      {:error, _} = error -> error
    end
  end

  defp perform(client, _, effect, "push", authorize, opts) do
    sha = effect["payload"]["sha"]

    if sent?(effect, "push") do
      case WriteClient.head(client) do
        {:ok, ^sha} -> {:ok, Map.put(effect["candidate"], "sha", sha)}
        _ -> {:error, :publication_push_unknown}
      end
    else
      publisher = Keyword.get(opts, :publisher, GitPublisher)

      with {:ok, candidate} <- publisher.candidate(client.settings, client.cycle, effect, opts),
           proof = Map.put(candidate.proof, "base_sha", Keyword.fetch!(opts, :base_sha)),
           :ok <- authorize.("push", proof),
           {:ok, result} <- publisher.push(client.settings, candidate, opts),
           true <- result == candidate.proof do
        {:ok, proof}
      else
        false -> {:error, :publication_push_unknown}
        error -> error
      end
    end
  end

  defp perform(client, _, effect, "pull", authorize, _) do
    with {:ok, pulls} <- WriteClient.pulls(client) do
      case pulls do
        [pr] -> confirm_pull(client, effect, pr)
        [] -> create_pull(client, effect, authorize)
        _ -> {:error, :publication_pr_ambiguous}
      end
    end
  end

  defp perform(client, _, effect, "comment", authorize, _) do
    marker = marker(client.cycle, "report")
    body = marker <> "\n" <> effect["payload"]["body"] <> report_suffix(client.cycle, effect)

    with {:ok, issue} <- WriteClient.issue(client),
         {:ok, comment} <- report_comment(issue.comments, marker, client.cycle),
         :ok <- write_report(client, effect, comment, body, authorize),
         {:ok, after_read} <- WriteClient.issue(client),
         {:ok, %{"id" => id, "body" => ^body}} <- report_comment(after_read.comments, marker, client.cycle) do
      {:ok, %{"comment_id" => id}}
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_report_unknown}
    end
  end

  defp perform(client, _, effect, "link", authorize, _) do
    pr = get_in(effect, ["steps", "pull", "result", "pr_id"])

    with {:ok, issue} <- WriteClient.issue(client),
         :ok <- write_link(client, effect, issue.links, pr, authorize),
         {:ok, after_read} <- WriteClient.issue(client),
         true <- pr in after_read.links do
      {:ok, %{"pr_id" => pr, "linked" => true}}
    else
      false -> {:error, :publication_link_unknown}
      error -> error
    end
  end

  defp perform(client, scope, effect, "status", authorize, _) do
    role = %{"start" => "working", "block" => "blocked", "publish" => "handoff"}[effect["kind"]]
    target = client.settings.project.states[role]

    with :ok <- write_status(client, scope, effect, role, target, authorize),
         {:ok, _} <- WriteClient.scope(client, [target]) do
      {:ok, %{"status" => target}}
    end
  end

  defp perform(client, _, effect, "finalize", _, _) do
    roles = if effect["status_owner"] == "controller", do: ~w(working handoff), else: ~w(handoff)

    with {:ok, _} <- WriteClient.scope(client, Enum.map(roles, &client.settings.project.states[&1])),
         {:ok, [pr]} <- WriteClient.pulls(client),
         {:ok, proof} <- confirm_pull(client, effect, pr),
         {:ok, issue} <- WriteClient.issue(client),
         true <- proof["pr_id"] in issue.links do
      {:ok, proof}
    else
      _ -> {:error, :handoff_readback_unconfirmed}
    end
  end

  defp create_pull(client, effect, authorize) do
    if sent?(effect, "pull") or client.cycle["work"]["pr_number"] != nil do
      {:error, :publication_pr_unknown}
    else
      create_new_pull(client, effect, authorize)
    end
  end

  defp create_new_pull(client, effect, authorize) do
    with {:ok, issue} <- WriteClient.issue(client) do
      url = "https://github.com/#{client.settings.repo}/issues/#{issue.number}"
      payload = effect["payload"] |> Map.update!("body", &(&1 <> "\n\n" <> marker(client.cycle, "pr") <> "\nTask and progress report: #{url}\nReadiness: Project status and CI."))

      post_pull(client, effect, authorize, payload)
    end
  end

  defp post_pull(client, effect, authorize, payload) do
    if Regex.match?(~r/\b(?:clos(?:e[sd]?)|fix(?:e[sd])?|resolv(?:e[sd]?))\s+(?:[\w.-]+\/[\w.-]+)?#\d+/i, payload["body"]) do
      {:error, :closing_keywords_not_allowed}
    else
      with :ok <- authorize.("pull", %{}), {:ok, _} <- WriteClient.create_pull(client, payload), {:ok, [pr]} <- WriteClient.pulls(client), do: confirm_pull(client, effect, pr)
    end
  end

  defp confirm_pull(client, effect, pr) do
    work = client.cycle["work"]

    valid =
      pr_open?(pr, client.settings.repo) and
        pr["head"]["ref"] == work["branch"] and pr["base"]["ref"] == "dev" and pr["head"]["sha"] == effect["payload"]["sha"] and
        is_integer(pr["number"]) and is_binary(pr["node_id"]) and
        associated?(client.cycle, pr)

    if valid, do: {:ok, %{"pr_number" => pr["number"], "pr_id" => pr["node_id"], "sha" => pr["head"]["sha"]}}, else: {:error, :publication_pr_changed}
  end

  defp associated?(cycle, pr) do
    cycle["work"]["pr_number"] == pr["number"] or
      (cycle["work"]["pr_number"] == nil and String.contains?(pr["body"] || "", marker(cycle, "pr")))
  end

  defp pr_open?(pr, repo) do
    pr["state"] == "open" and pr["draft"] == false and pr["merged_at"] == nil and
      pr["head"]["repo"]["full_name"] == repo and pr["base"]["repo"]["full_name"] == repo
  end

  defp write_report(_, _, %{"body" => body}, body, _), do: :ok

  defp write_report(client, effect, comment, body, authorize) do
    id = if comment, do: comment["id"]

    if sent?(effect, "comment") do
      {:error, :publication_report_unknown}
    else
      with :ok <- authorize.("comment", %{}), {:ok, _} <- WriteClient.report(client, id, body), do: :ok
    end
  end

  defp report_comment(comments, marker, cycle) do
    ids = Map.get(cycle, "effects", %{}) |> Map.values() |> Enum.map(&get_in(&1, ["steps", "comment", "result", "comment_id"])) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    matches = Enum.filter(comments, &String.starts_with?(&1["body"] || "", marker <> "\n"))

    case matches do
      [] when ids == [] ->
        {:ok, nil}

      [%{"viewerDidAuthor" => true, "author" => %{"__typename" => "Bot"}} = comment] ->
        if ids in [[], [comment["id"]]], do: {:ok, comment}, else: {:error, :publication_report_changed}

      _ ->
        {:error, :publication_report_changed}
    end
  end

  defp write_link(client, effect, links, pr, authorize) do
    cond do
      pr in links -> :ok
      sent?(effect, "link") -> {:error, :publication_link_unknown}
      true -> with :ok <- authorize.("link", %{}), {:ok, _} <- WriteClient.link(client, pr), do: :ok
    end
  end

  defp write_status(client, scope, effect, role, target, authorize) do
    cond do
      scope.row["state"] == target -> :ok
      sent?(effect, "status") -> {:error, :publication_status_unknown}
      scope.row["state"] not in [client.settings.project.states["ready"], client.settings.project.states["working"]] -> {:error, :publication_status_changed}
      true -> with :ok <- authorize.("status", %{}), {:ok, _} <- WriteClient.status(client, scope, role), do: :ok
    end
  end

  defp report_suffix(cycle, %{"kind" => "publish"}),
    do: "\n\nPR ##{cycle["work"]["pr_number"]}; SHA #{cycle["work"]["head_sha"]}; CI evidence: " <> Jason.encode!(Budget.latest_ci(cycle["budget"]))

  defp report_suffix(_, _), do: ""
  defp sent?(effect, step), do: get_in(effect, ["steps", step, "status"]) == "sent"
  defp marker(cycle, kind), do: "<!-- symphony:#{kind}:#{cycle["id"]}:#{cycle["task"]["item_id"]} -->"
end
