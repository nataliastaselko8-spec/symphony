defmodule SymphonyElixir.GitHubProjects.Client do
  @moduledoc """
  Finite, query-only GitHub Projects snapshots. Partial responses are errors.

  The injected request function receives (query, variables, resolved_settings).
  It must return an HTTP status and decoded GraphQL body, like Req.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Credentials
  alias SymphonyElixir.GitHubProjects.{Normalizer, Schema, Settings}
  alias SymphonyElixir.Tracker.Issue

  @page_size 100
  @node_batch_size 50
  @default_max_pages 100
  @page_info "pageInfo { hasNextPage endCursor }"
  @identity_query """
  query SymphonyProjectIdentity($organization: String!, $number: Int!, $repository: String!) {
    organization(login: $organization) {
      projectV2(number: $number) { id number title url owner { ... on Organization { login } } }
    }
    repository(owner: $organization, name: $repository) { id nameWithOwner }
  }
  """
  @fields_query """
  query SymphonyProjectFields($id: ID!, $cursor: String) {
    node(id: $id) {
      __typename
      ... on ProjectV2 {
        id
        fields(first: 100, after: $cursor) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon { id name dataType }
            ... on ProjectV2SingleSelectField { options { id name } }
          }
          #{@page_info}
        }
      }
    }
  }
  """

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- Settings.parse(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Settings.secret_environment_names(tracker_settings)

  @spec inspect(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(tracker_settings, opts \\ []) do
    with {:ok, settings} <- Settings.parse(tracker_settings),
         {:ok, project, schema} <- discover(settings, opts),
         {:ok, items} <- project_items(project, schema, settings, opts),
         {:ok, normalized} <- normalize_items(items, project, schema, settings, opts) do
      rows = Enum.map(normalized, fn {_issue, row} -> row end)
      eligible = Enum.count(rows, & &1["eligible"])

      {:ok,
       %{
         "execution_enabled" => false,
         "eligibility_scope" => "project_fields_only",
         "project" => project,
         "schema" => Schema.report(schema),
         "diagnostics" => schema.diagnostics ++ missing_selected_items(rows, settings),
         "items" => rows,
         "summary" => %{"total" => length(rows), "eligible" => eligible, "excluded" => length(rows) - eligible}
       }}
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states, opts \\ []) when is_list(states) do
    with {:ok, settings} <- settings(opts),
         {:ok, project, schema} <- discover(settings, opts),
         {:ok, items} <- project_items(project, schema, settings, opts),
         {:ok, normalized} <- normalize_items(items, project, schema, settings, opts) do
      {:ok,
       normalized
       |> Enum.map(&elem(&1, 0))
       |> Enum.filter(fn
         %Issue{state: state} -> state in states
         _issue -> false
       end)}
    end
  end

  @spec fetch_issues_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids, opts \\ []) when is_list(ids) do
    with :ok <- validate_ids(ids),
         {:ok, settings} <- settings(opts),
         {:ok, project, schema} <- discover(settings, opts),
         {:ok, items} <- fetch_nodes(Enum.uniq(ids), project, schema, settings, opts),
         {:ok, normalized} <- normalize_items(items, project, schema, settings, opts),
         :ok <- validate_refresh(normalized) do
      {:ok, normalized |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)}
    end
  end

  defp settings(opts) do
    opts
    |> Keyword.get_lazy(:tracker_settings, fn -> Config.settings!().tracker end)
    |> Settings.parse()
  end

  defp discover(settings, opts) do
    variables = %{
      "organization" => settings.organization,
      "number" => settings.project_number,
      "repository" => settings.repo |> String.split("/") |> List.last()
    }

    with {:ok, data} <- query(@identity_query, variables, settings, opts),
         {:ok, project} <- project_identity(data, settings),
         {:ok, fields} <- project_pages(@fields_query, %{}, project, "fields", settings, opts),
         {:ok, schema} <- Schema.resolve(fields, settings) do
      {:ok, project, schema}
    end
  end

  defp project_identity(data, settings) do
    project = nested(data["organization"], "projectV2")
    repository = data["repository"]

    if is_map(project) and present?(project["id"]) and project["number"] == settings.project_number and
         same_name?(nested(project["owner"], "login"), settings.organization) and
         is_map(repository) and present?(repository["id"]) and same_name?(repository["nameWithOwner"], settings.repo) do
      {:ok,
       project
       |> Map.take(["id", "number", "title", "url"])
       |> Map.put("organization", settings.organization)
       |> Map.put("repo", settings.repo)
       |> Map.put("repository_id", repository["id"])}
    else
      {:error, :github_projects_scope_unavailable}
    end
  end

  defp project_items(project, schema, settings, opts) do
    {selection, declarations, variables} = item_selection(schema)

    graphql = """
    query SymphonyProjectItems($id: ID!, $cursor: String#{declarations}) {
      node(id: $id) {
        __typename
        ... on ProjectV2 {
          id
          items(first: #{@page_size}, after: $cursor, archivedStates: [ARCHIVED, NOT_ARCHIVED]) {
            nodes { #{selection} }
            #{@page_info}
          }
        }
      }
    }
    """

    project_pages(graphql, variables, project, "items", settings, opts)
  end

  defp project_pages(graphql, variables, project, connection, settings, opts) do
    pages(
      fn cursor ->
        variables = Map.merge(variables, %{"id" => project["id"], "cursor" => cursor})

        with {:ok, data} <- query(graphql, variables, settings, opts),
             {:ok, node} <- expected_node(data["node"], "ProjectV2", project["id"]) do
          {:ok, node[connection]}
        end
      end,
      opts
    )
  end

  defp fetch_nodes([], _project, _schema, _settings, _opts), do: {:ok, []}

  defp fetch_nodes(ids, project, schema, settings, opts) do
    {selection, declarations, variables} = item_selection(schema)

    graphql = """
    query SymphonyProjectNodes($ids: [ID!]!#{declarations}) {
      nodes(ids: $ids) { __typename ... on ProjectV2Item { #{selection} } }
    }
    """

    with {:ok, nodes} <-
           traverse(Enum.chunk_every(ids, @node_batch_size), fn batch ->
             fetch_node_batch(graphql, Map.put(variables, "ids", batch), settings, opts)
           end) do
      reconcile_nodes(List.flatten(nodes), project, settings, opts)
    end
  end

  defp fetch_node_batch(graphql, variables, settings, opts) do
    with {:ok, data} <- query(graphql, variables, settings, opts, :nodes),
         :ok <- validate_nodes(data["nodes"], variables["ids"]) do
      {:ok, Enum.zip(variables["ids"], data["nodes"])}
    end
  end

  defp validate_nodes(nodes, ids) when is_list(nodes) and length(nodes) == length(ids) do
    if Enum.zip(ids, nodes)
       |> Enum.all?(fn
         {_id, nil} -> true
         {id, %{"__typename" => "ProjectV2Item", "id" => id}} -> true
         _pair -> false
       end) do
      :ok
    else
      {:error, :github_projects_invalid_nodes}
    end
  end

  defp validate_nodes(_nodes, _ids), do: {:error, :github_projects_invalid_nodes}

  defp reconcile_nodes(pairs, project, settings, opts) do
    if Enum.any?(pairs, fn {_id, node} -> is_nil(node) end) do
      with {:ok, existing} <- project_item_ids(project, settings, opts) do
        reject_unresolved_nodes(pairs, existing)
      end
    else
      {:ok, Enum.map(pairs, &elem(&1, 1))}
    end
  end

  defp reject_unresolved_nodes(pairs, existing) do
    if Enum.any?(pairs, fn {id, node} -> is_nil(node) and id in existing end),
      do: {:error, :github_projects_item_unavailable},
      else: {:ok, pairs |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)}
  end

  defp project_item_ids(project, settings, opts) do
    graphql = """
    query SymphonyProjectItemInventory($id: ID!, $cursor: String) {
      node(id: $id) {
        __typename
        ... on ProjectV2 {
          id
          items(first: #{@page_size}, after: $cursor, archivedStates: [ARCHIVED, NOT_ARCHIVED]) {
            nodes { id }
            #{@page_info}
          }
        }
      }
    }
    """

    with {:ok, items} <- project_pages(graphql, %{}, project, "items", settings, opts),
         :ok <- unique_ids(items) do
      {:ok, Enum.map(items, & &1["id"])}
    end
  end

  defp normalize_items(items, project, schema, settings, opts) do
    with :ok <- unique_ids(items) do
      traverse(items, &normalize_item(&1, project, schema, settings, opts))
    end
  end

  defp normalize_item(item, project, schema, settings, opts) do
    with {:ok, item} <- complete_issue_connections(item, settings, opts) do
      Normalizer.normalize(item, project, schema, settings)
    end
  end

  defp complete_issue_connections(%{"content" => %{"__typename" => "Issue"} = issue} = item, settings, opts) do
    with true <- present?(issue["id"]) or {:error, :github_projects_invalid_issue},
         {:ok, labels} <- issue_connection(issue, "labels", "name", settings, opts),
         {:ok, assignees} <- issue_connection(issue, "assignees", "login", settings, opts) do
      {:ok, Map.put(item, "content", Map.merge(issue, %{"labels" => labels, "assignees" => assignees}))}
    end
  end

  defp complete_issue_connections(item, _settings, _opts), do: {:ok, item}

  defp issue_connection(issue, connection, field, settings, opts) do
    graphql = """
    query SymphonyIssueConnection($id: ID!, $cursor: String) {
      node(id: $id) {
        __typename
        ... on Issue {
          id
          #{connection}(first: #{@page_size}, after: $cursor) { nodes { #{field} } #{@page_info} }
        }
      }
    }
    """

    pages(
      fn
        nil ->
          {:ok, issue[connection]}

        cursor ->
          with {:ok, data} <- query(graphql, %{"id" => issue["id"], "cursor" => cursor}, settings, opts),
               {:ok, node} <- expected_node(data["node"], "Issue", issue["id"]) do
            {:ok, node[connection]}
          end
      end,
      opts
    )
  end

  defp item_selection(schema) do
    fields = [schema.status, schema.allowed | schema.context]

    declarations =
      fields |> Enum.with_index() |> Enum.map_join("", fn {_field, index} -> ", $field#{index}: String!" end)

    variables =
      fields |> Enum.with_index() |> Map.new(fn {field, index} -> {"field#{index}", field["name"]} end)

    selections =
      fields
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {_field, index} ->
        """
        field_#{index}: fieldValueByName(name: $field#{index}) {
          __typename
          ... on ProjectV2ItemFieldValueCommon { field { ... on ProjectV2FieldCommon { id } } }
          ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
          ... on ProjectV2ItemFieldTextValue { text }
          ... on ProjectV2ItemFieldNumberValue { number }
          ... on ProjectV2ItemFieldDateValue { date }
          ... on ProjectV2ItemFieldIterationValue { title iterationId }
        }
        """
      end)

    selection = """
    id isArchived type project { id }
    #{selections}
    content {
      __typename
      ... on Issue {
        id number title body url state createdAt updatedAt repository { nameWithOwner }
        labels(first: #{@page_size}) { nodes { name } #{@page_info} }
        assignees(first: #{@page_size}) { nodes { login } #{@page_info} }
      }
    }
    """

    {selection, declarations, variables}
  end

  defp pages(fetch, opts) do
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)

    if is_integer(max_pages) and max_pages in 1..1_000,
      do: pages(fetch, nil, %{}, max_pages, []),
      else: {:error, :github_projects_invalid_page_limit}
  end

  @spec pages(function(), term(), map(), non_neg_integer(), [[map()]]) ::
          {:ok, [map()]} | {:error, term()}
  defp pages(_fetch, _cursor, _seen, 0, _acc), do: {:error, :github_projects_page_limit}

  defp pages(fetch, cursor, seen, remaining, acc) do
    with {:ok, connection} <- fetch.(cursor),
         {:ok, nodes, next} <- connection_page(connection),
         :ok <- next_cursor(next, seen, nodes) do
      acc = [nodes | acc]

      if is_nil(next) do
        {:ok, acc |> Enum.reverse() |> List.flatten()}
      else
        pages(fetch, next, Map.put(seen, next, true), remaining - 1, acc)
      end
    end
  end

  defp connection_page(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}})
       when is_list(nodes) and is_boolean(has_next) do
    cond do
      not Enum.all?(nodes, &is_map/1) -> {:error, :github_projects_invalid_connection}
      has_next and not present?(cursor) -> {:error, :github_projects_incomplete_pagination}
      true -> {:ok, nodes, if(has_next, do: cursor)}
    end
  end

  defp connection_page(_connection), do: {:error, :github_projects_invalid_connection}

  @spec next_cursor(term(), map(), [map()]) :: :ok | {:error, atom()}
  defp next_cursor(nil, _seen, _nodes), do: :ok

  defp next_cursor(cursor, seen, nodes) do
    if nodes == [] or Map.has_key?(seen, cursor),
      do: {:error, :github_projects_incomplete_pagination},
      else: :ok
  end

  defp unique_ids(items) do
    ids = Enum.map(items, & &1["id"])

    if Enum.all?(ids, &present?/1) and length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, :github_projects_duplicate_or_invalid_items}
  end

  defp validate_refresh(normalized) do
    if Enum.any?(normalized, fn {_issue, row} ->
         row["in_scope"] and Enum.any?(row["reasons"], &(&1 in ["missing_status", "invalid_status"]))
       end),
       do: {:error, :github_projects_invalid_refresh_status},
       else: :ok
  end

  defp validate_ids(ids) do
    if length(ids) <= 10_000 and Enum.all?(ids, &present?/1),
      do: :ok,
      else: {:error, :invalid_github_projects_item_ids}
  end

  defp query(graphql, variables, settings, opts, mode \\ :normal) do
    request_fun =
      Keyword.get(opts, :request_fun, fn query, vars, config ->
        perform_request(query, vars, config, Keyword.get(opts, :req_adapter))
      end)

    with {:ok, token} <- request_token(settings, opts) do
      response = safe_request(request_fun, graphql, variables, Map.put(settings, :token, token))
      invalidate_unauthorized(response, settings, token, opts)
      query_response(response, mode)
    end
  end

  defp query_response(response, mode) do
    case response do
      {:ok, %{status: 200, body: %{} = body}} ->
        graphql_data(body, mode)

      {:ok, %{status: status} = response} when is_integer(status) ->
        {:error, {:github_projects_http, status, retry_after(response)}}

      {:error, _reason} ->
        {:error, :github_projects_transport_error}

      _response ->
        {:error, :github_projects_invalid_response}
    end
  end

  defp request_token(%{credential_reference: nil, token: token}, _opts), do: {:ok, token}
  defp request_token(%{credential_reference: reference}, opts), do: Credentials.token(reference, opts)

  defp invalidate_unauthorized({:ok, %{status: 401}}, %{credential_reference: reference}, token, opts)
       when not is_nil(reference) do
    Credentials.invalidate(reference, token, opts)
  end

  defp invalidate_unauthorized(_response, _settings, _token, _opts), do: :ok

  defp safe_request(request_fun, graphql, variables, settings) do
    request_fun.(graphql, variables, settings)
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp graphql_data(%{"errors" => errors, "data" => %{"nodes" => nodes}} = body, :nodes)
       when is_list(errors) and errors != [] and is_list(nodes) do
    if Enum.all?(errors, &missing_node_error?(&1, nodes)),
      do: graphql_data(Map.delete(body, "errors")),
      else: {:error, :github_projects_graphql_errors}
  end

  defp graphql_data(body, _mode), do: graphql_data(body)

  defp missing_node_error?(%{"type" => "NOT_FOUND", "path" => ["nodes", index]}, nodes)
       when is_integer(index) and index >= 0 and index < length(nodes) do
    is_nil(Enum.at(nodes, index))
  end

  defp missing_node_error?(_error, _nodes), do: false

  defp graphql_data(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: {:error, :github_projects_graphql_errors}

  defp graphql_data(%{"errors" => errors}) when not is_list(errors),
    do: {:error, :github_projects_invalid_response}

  defp graphql_data(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp graphql_data(_body), do: {:error, :github_projects_invalid_response}

  defp perform_request(graphql, variables, settings, adapter) do
    request = if is_nil(adapter), do: Req.new(), else: Req.new(adapter: adapter)

    case Req.post(request,
           url: settings.endpoint,
           json: %{"query" => graphql, "variables" => variables},
           headers: [
             {"authorization", "Bearer #{settings.token}"},
             {"accept", "application/vnd.github+json"},
             {"user-agent", "symphony"}
           ],
           redirect: false,
           retry: false,
           connect_options: [timeout: 15_000],
           receive_timeout: 30_000
         ) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body, headers: response.headers}}
      {:error, _reason} -> {:error, :request_failed}
    end
  end

  defp retry_after(response) do
    case response |> Map.get(:headers, %{}) |> header_value("retry-after") do
      [value] -> positive_seconds(value)
      value -> positive_seconds(value)
    end
  end

  defp header_value(headers, name) when is_map(headers), do: Map.get(headers, name)

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _header -> nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp nested(value, key) when is_map(value), do: value[key]
  defp nested(_value, _key), do: nil

  defp missing_selected_items(_rows, %{item_ids: nil}), do: []

  defp missing_selected_items(rows, settings) do
    present_ids = MapSet.new(rows, & &1["item_id"])

    settings.item_ids
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(present_ids, &1))
    |> Enum.map(&%{"code" => "missing_selected_item", "item_id" => &1})
  end

  defp positive_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _value -> nil
    end
  end

  defp positive_seconds(_value), do: nil

  defp expected_node(%{"__typename" => type, "id" => id} = node, type, id), do: {:ok, node}
  defp expected_node(_node, _type, _id), do: {:error, :github_projects_scope_unavailable}

  defp traverse(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp same_name?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_name?(_left, _right), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
