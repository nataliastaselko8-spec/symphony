defmodule SymphonyElixir.GitHubProjects.WriteClient do
  @moduledoc "Fixed task operations. No caller-selected HTTP methods, URLs, fields or destinations."
  alias SymphonyElixir.GitHub.Credentials
  alias SymphonyElixir.GitHubProjects.{Client, Delivery}

  @issue """
  query SymphonyPublicationIssue($id: ID!, $cursor: String) {
    node(id: $id) { ... on Issue { id number state repository { nameWithOwner }
      comments(first: 100, after: $cursor) { nodes { id body viewerDidAuthor author { __typename } }
        pageInfo { hasNextPage endCursor } }
      closedByPullRequestsReferences(first: 100, includeClosedPrs: true) { nodes { id } pageInfo { hasNextPage } }
    } }
  }
  """
  @add "mutation SymphonyReport($input: AddCommentInput!) { addComment(input: $input) { commentEdge { node { id } } } }"
  @update "mutation SymphonyReportUpdate($input: UpdateIssueCommentInput!) { updateIssueComment(input: $input) { issueComment { id } } }"
  @link "mutation SymphonyLink($input: AddCloseIssueReferencesInput!) { addCloseIssueReferences(input: $input) { clientMutationId } }"
  @status "mutation SymphonyStatus($input: UpdateProjectV2ItemFieldValueInput!) { updateProjectV2ItemFieldValue(input: $input) { projectV2Item { id } } }"

  @spec new(map(), map(), keyword()) :: map()
  def new(settings, cycle, opts), do: %{settings: settings, cycle: cycle, opts: opts}

  @spec scope(map(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def scope(client, states) do
    reader = Keyword.get(client.opts, :project_reader, &Client.inspect/2)

    with {:ok, report} <- reader.(client.settings.tracker, client.opts),
         [row] <- Enum.filter(report["items"], &(&1["item_id"] == client.cycle["task"]["item_id"])),
         true <- row["native_ref"]["issue_id"] == client.cycle["task"]["issue_id"] and row["native_ref"]["repo"] == client.settings.repo,
         true <- row["archived"] == false and row["issue_state"] == "OPEN" and row["state"] in states,
         true <- Enum.all?(row["reasons"], &(&1 == "inactive_status")),
         true <- row["native_ref"]["agent_allowed_option_id"] == report["schema"]["agent_allowed_option_id"],
         true <- selected?(client.settings.project.item_ids, row["item_id"]) do
      {:ok, %{row: row, project: report["project"], schema: report["schema"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_scope_changed}
    end
  end

  @spec issue(map()) :: {:ok, map()} | {:error, term()}
  def issue(client), do: issue_pages(client, nil, [], [])

  defp issue_pages(client, cursor, acc, seen) do
    with true <- length(seen) < 100 and cursor not in seen,
         {:ok, %{"node" => node}} <- graphql(client, @issue, %{"id" => client.cycle["task"]["issue_id"], "cursor" => cursor}),
         true <- node["id"] == client.cycle["task"]["issue_id"] and node["state"] == "OPEN" and node["repository"]["nameWithOwner"] == client.settings.repo,
         %{"nodes" => comments, "pageInfo" => page} <- node["comments"],
         true <- is_list(comments) and length(comments) <= 100,
         links when is_list(links) <- node["closedByPullRequestsReferences"]["nodes"],
         false <- node["closedByPullRequestsReferences"]["pageInfo"]["hasNextPage"] do
      all = acc ++ comments

      if page["hasNextPage"] == true and is_binary(page["endCursor"]),
        do: issue_pages(client, page["endCursor"], all, [cursor | seen]),
        else: finish_issue(node, page, all, links)
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_issue_unconfirmed}
    end
  end

  defp finish_issue(node, %{"hasNextPage" => false}, comments, links) do
    if length(Enum.uniq_by(comments, & &1["id"])) == length(comments),
      do: {:ok, %{number: node["number"], comments: comments, links: Enum.map(links, & &1["id"])}},
      else: {:error, :publication_comments_changed}
  end

  defp finish_issue(_, _, _, _), do: {:error, :publication_issue_unconfirmed}

  @spec pulls(map()) :: {:ok, list()} | {:error, term()}
  def pulls(client), do: pull_pages(client, 1, [])

  defp pull_pages(client, page, acc) do
    head = hd(String.split(client.settings.repo, "/")) <> ":" <> client.cycle["work"]["branch"]

    with true <- page <= 100,
         params = %{state: "all", head: head, per_page: 100, page: page},
         {:ok, pulls} when is_list(pulls) <- request(client, :get, "/pulls", nil, params, :publication),
         true <- length(pulls) <= 100 and Enum.all?(pulls, &is_map/1),
         all = acc ++ pulls,
         true <- length(Enum.uniq_by(all, & &1["id"])) == length(all) do
      if length(pulls) < 100, do: {:ok, all}, else: pull_pages(client, page + 1, all)
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_pulls_unconfirmed}
    end
  end

  @spec create_pull(map(), map()) :: {:ok, term()} | {:error, term()}
  def create_pull(client, payload) do
    body = Map.merge(Map.take(payload, ~w(title body)), %{"head" => client.cycle["work"]["branch"], "base" => "dev", "draft" => false, "maintainer_can_modify" => false})
    request(client, :post, "/pulls", body, %{}, :publication)
  end

  @spec report(map(), String.t() | nil, String.t()) :: {:ok, term()} | {:error, term()}
  def report(client, nil, body), do: graphql(client, @add, %{"input" => %{"subjectId" => client.cycle["task"]["issue_id"], "body" => body}})
  def report(client, id, body), do: graphql(client, @update, %{"input" => %{"id" => id, "body" => body}})

  @spec link(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def link(client, id), do: graphql(client, @link, %{"input" => %{"issueId" => client.cycle["task"]["issue_id"], "pullRequestIds" => [id]}})

  @spec status(map(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  def status(client, scope, role) when role in ~w(working blocked handoff review dev_validation production_ready) do
    write_status(client, scope, role, false)
  end

  @spec sync_status(map(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  def sync_status(client, scope, role), do: write_status(client, scope, role, true)

  defp write_status(client, scope, role, sync) do
    name = client.settings.project.states[role]
    field = scope.schema["status"]

    case Enum.filter(field["options"], &(&1["name"] == name)) do
      [%{"id" => option}] ->
        input = %{"projectId" => scope.project["id"], "itemId" => client.cycle["task"]["item_id"], "fieldId" => field["id"], "value" => %{"singleSelectOptionId" => option}}

        if sync do
          body = %{"query" => @status, "variables" => %{"input" => input}}
          request(client, :post, :graphql, body, %{}, :projects_write, &decode_status/1)
        else
          graphql(client, @status, %{"input" => input}, :projects_write)
        end

      _ ->
        {:error, :publication_status_unconfirmed}
    end
  end

  @spec dev(map()) :: {:ok, String.t()} | {:error, term()}
  def dev(client) do
    reader = Delivery.Client.new(client.settings, client.opts)
    Delivery.Ownership.ref(reader)
  end

  @spec head(map()) :: {:ok, String.t()} | {:error, term()}
  def head(client) do
    branch = client.cycle["work"]["branch"]
    response = request(client, :get, "/git/ref/heads/" <> branch, nil, %{}, :delivery_read)

    with {:ok, %{"ref" => ref, "object" => %{"type" => "commit", "sha" => sha}}} <- response,
         true <- ref == "refs/heads/" <> branch and Delivery.Settings.sha?(sha),
         do: {:ok, sha},
         else: (_ -> {:error, :publication_head_unconfirmed})
  end

  defp graphql(client, query, variables, profile \\ :publication) do
    case request(client, :post, :graphql, %{"query" => query, "variables" => variables}, %{}, profile) do
      {:ok, %{"data" => data} = body} when is_map(data) ->
        if Map.get(body, "errors", []) == [], do: {:ok, data}, else: {:error, :publication_graphql_unknown}

      {:error, _} = error ->
        error

      _ ->
        {:error, :publication_graphql_unknown}
    end
  end

  defp request(client, method, path, body, params, profile, decoder \\ &decode/1) do
    with {:ok, reference} <- Credentials.reference(client.settings.tracker.provider, profile),
         {:ok, token} <- Credentials.token(reference, client.opts) do
      url = if path == :graphql, do: "https://api.github.com/graphql", else: "https://api.github.com/repos/" <> reference.repo <> path

      options = [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer " <> token}, {"accept", "application/vnd.github+json"}],
        params: params,
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: 30_000,
        connect_options: [timeout: 10_000],
        into: &collect/2
      ]

      options = if body, do: Keyword.put(options, :json, body), else: options
      response = Keyword.get(client.opts, :http, &Req.request/1).(options)
      if match?({:ok, %{status: 401}}, response), do: Credentials.invalidate(reference, token, client.opts)
      decoder.(response)
    end
  rescue
    _ -> {:error, :publication_transport_unknown}
  catch
    _, _ -> {:error, :publication_transport_unknown}
  end

  defp collect({:data, bytes}, {request, response}) do
    body = response.body <> bytes

    if byte_size(body) <= 5_242_880 do
      {:cont, {request, %{response | body: body}}}
    else
      {:halt, {request, %{response | status: 413, body: ""}}}
    end
  end

  defp decode({:ok, %{status: status, body: body}}) when status in [200, 201], do: Delivery.JSON.decode(body, 5_242_880)

  defp decode({:ok, %{status: status, headers: headers}}) when status in [403, 429] do
    value = headers |> Map.new() |> Map.get("retry-after", ["60"]) |> List.wrap() |> List.first()

    seconds =
      case Integer.parse(to_string(value)) do
        {n, ""} when n > 0 -> min(n, 86_400)
        _ -> 60
      end

    {:error, {:publication_limited, seconds}}
  end

  defp decode(_), do: {:error, :publication_result_unknown}

  defp decode_status({:ok, %{status: code, headers: headers}} = response) when code in [403, 429] do
    headers = Map.new(headers)
    if code == 429 or Map.has_key?(headers, "retry-after") or Map.get(headers, "x-ratelimit-remaining") in ["0", ["0"]], do: decode(response), else: {:error, :status_permission_denied}
  end

  defp decode_status({:ok, %{status: code}}) when code in [400, 401, 404, 422], do: {:error, :status_write_refused}

  defp decode_status(response) do
    case decode(response) do
      {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => _}}}} = body} ->
        if Map.get(body, "errors", []) == [], do: {:ok, body}, else: {:error, :status_write_unknown}

      {:error, _} = error ->
        error

      _ ->
        {:error, :status_write_unknown}
    end
  end

  defp selected?(nil, _), do: true
  defp selected?(ids, id), do: id in ids
end
