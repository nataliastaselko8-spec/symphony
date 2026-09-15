defmodule SymphonyElixir.GitHubProjects.Normalizer do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @spec normalize(map(), map(), map(), map()) :: {:ok, {Issue.t() | nil, map()}} | {:error, term()}
  def normalize(item, project, schema, settings) do
    with :ok <- validate_item(item),
         :ok <- validate_field_identity(item, schema),
         :ok <- validate_content(item["content"]) do
      {state, status_reason} = select_value(item["field_0"], schema.status, "status")
      {allowed, allowed_reason} = select_value(item["field_1"], schema.allowed, "agent_allowed")
      {context, diagnostics} = context_values(item, schema.context)
      content = item["content"] || %{}
      reasons = reasons(item, project, settings, state, status_reason, allowed, allowed_reason)
      in_scope = scope_reasons(item, project, settings) == []
      native_ref = native_ref(item, project, schema, content, context)
      issue = build_issue(item, content, state, native_ref, reasons, in_scope)
      eligible = match?(%Issue{dispatchable: true}, issue) and state in settings.active_states
      reasons = if state && state not in settings.active_states, do: reasons ++ ["inactive_status"], else: reasons
      label_reasons = required_label_reasons(issue, settings.required_labels)

      row = %{
        "item_id" => item["id"],
        "identifier" => identifier(item["id"]),
        "state" => state,
        "issue_state" => content["state"],
        "title" => content["title"],
        "url" => content["url"],
        "archived" => item["isArchived"],
        "in_scope" => in_scope,
        "eligible" => eligible and label_reasons == [],
        "reasons" => Enum.uniq(reasons ++ label_reasons),
        "diagnostics" => diagnostics,
        "native_ref" => native_ref
      }

      {:ok, {issue, row}}
    end
  end

  defp validate_item(%{"id" => id, "isArchived" => archived, "project" => %{"id" => project_id}} = item)
       when is_binary(id) and is_boolean(archived) and is_binary(project_id) do
    if present?(id) and present?(project_id) and Map.has_key?(item, "content"),
      do: :ok,
      else: {:error, :github_projects_invalid_item}
  end

  defp validate_item(_item), do: {:error, :github_projects_invalid_item}

  defp validate_field_identity(item, schema) do
    [schema.status, schema.allowed | schema.context]
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {field, index}, :ok ->
      key = "field_#{index}"
      field_id = field["id"]

      case Map.fetch(item, key) do
        {:ok, nil} ->
          {:cont, :ok}

        {:ok, %{"field" => %{"id" => id}}} when id == field_id ->
          {:cont, :ok}

        _value ->
          {:halt, {:error, :github_projects_field_identity_mismatch}}
      end
    end)
  end

  defp validate_content(%{"__typename" => "Issue"} = issue) do
    if present?(issue["id"]) and present?(issue["title"]) and
         is_integer(issue["number"]) and issue["number"] > 0 and
         issue["state"] in ["OPEN", "CLOSED"] and
         match?(%{"nameWithOwner" => name} when is_binary(name), issue["repository"]) and
         valid_labels?(issue["labels"]) and valid_assignees?(issue["assignees"]) do
      :ok
    else
      {:error, :github_projects_invalid_issue}
    end
  end

  defp validate_content(nil), do: :ok
  defp validate_content(%{"__typename" => type}) when type in ["DraftIssue", "PullRequest"], do: :ok
  defp validate_content(_content), do: {:error, :github_projects_invalid_content}

  defp valid_labels?(labels) when is_list(labels),
    do: Enum.all?(labels, &match?(%{"name" => name} when is_binary(name), &1))

  defp valid_labels?(_labels), do: false

  defp valid_assignees?(assignees) when is_list(assignees),
    do: Enum.all?(assignees, &match?(%{"login" => login} when is_binary(login), &1))

  defp valid_assignees?(_assignees), do: false

  defp select_value(nil, _field, role), do: {nil, "missing_#{role}"}

  defp select_value(%{"__typename" => "ProjectV2ItemFieldSingleSelectValue", "optionId" => id, "name" => name}, field, role) do
    if Enum.any?(field["options"], &(&1["id"] == id and &1["name"] == name)) and present?(name),
      do: {name, nil},
      else: {nil, "invalid_#{role}"}
  end

  defp select_value(_value, _field, role), do: {nil, "invalid_#{role}"}

  defp context_values(item, fields) do
    fields
    |> Enum.with_index(2)
    |> Enum.reduce({%{}, []}, fn {field, index}, acc ->
      add_context_value(context_value(item["field_#{index}"], field), field, acc)
    end)
  end

  defp add_context_value({:ok, value}, field, {values, diagnostics}) do
    updated = Map.put(values, field["name"], %{"field_id" => field["id"], "value" => value})

    if is_nil(value),
      do: {updated, diagnostics ++ [%{"code" => "empty_context_value", "field" => field["name"]}]},
      else: {updated, diagnostics}
  end

  defp add_context_value(:invalid, field, {values, diagnostics}) do
    {values, diagnostics ++ [%{"code" => "invalid_context_value", "field" => field["name"]}]}
  end

  defp context_value(nil, _field), do: {:ok, nil}

  defp context_value(%{"__typename" => "ProjectV2ItemFieldTextValue", "text" => text}, %{"dataType" => "TEXT"})
       when is_binary(text),
       do: {:ok, text}

  defp context_value(%{"__typename" => "ProjectV2ItemFieldNumberValue", "number" => number}, %{"dataType" => "NUMBER"})
       when is_number(number),
       do: {:ok, number}

  defp context_value(%{"__typename" => "ProjectV2ItemFieldDateValue", "date" => date}, %{"dataType" => "DATE"})
       when is_binary(date),
       do: {:ok, date}

  defp context_value(%{"__typename" => "ProjectV2ItemFieldIterationValue", "title" => title, "iterationId" => id}, %{"dataType" => "ITERATION"})
       when is_binary(title) and is_binary(id),
       do: {:ok, %{"id" => id, "title" => title}}

  defp context_value(value, %{"dataType" => "SINGLE_SELECT"} = field) do
    case select_value(value, field, "context") do
      {name, nil} -> {:ok, %{"option_id" => value["optionId"], "name" => name}}
      _value -> :invalid
    end
  end

  defp context_value(_value, _field), do: :invalid

  defp reasons(item, project, settings, _state, status_reason, allowed, allowed_reason) do
    scope_reasons(item, project, settings) ++
      if(item["isArchived"], do: ["archived"], else: []) ++
      content_reasons(item["content"]) ++
      if(status_reason, do: [status_reason], else: []) ++
      cond do
        allowed_reason -> [allowed_reason]
        allowed != settings.allowed_value -> ["agent_not_allowed"]
        true -> []
      end
  end

  defp scope_reasons(item, project, settings) do
    project_reasons = if item["project"]["id"] != project["id"], do: ["outside_project_scope"], else: []
    item_reasons = if is_list(settings.item_ids) and item["id"] not in settings.item_ids, do: ["outside_item_scope"], else: []
    repo_reasons = repo_scope_reason(item["content"], settings.repo)
    project_reasons ++ item_reasons ++ repo_reasons
  end

  defp repo_scope_reason(%{"__typename" => "Issue", "repository" => %{"nameWithOwner" => repo}}, allowed) do
    if String.downcase(repo) == String.downcase(allowed), do: [], else: ["outside_repo_scope"]
  end

  defp repo_scope_reason(_content, _allowed), do: []

  defp content_reasons(nil), do: ["redacted_content"]
  defp content_reasons(%{"__typename" => "DraftIssue"}), do: ["draft_item"]
  defp content_reasons(%{"__typename" => "PullRequest"}), do: ["pull_request_item"]
  defp content_reasons(%{"__typename" => "Issue", "state" => "CLOSED"}), do: ["closed_issue"]
  defp content_reasons(_content), do: []

  defp native_ref(item, project, schema, content, context) do
    %{
      "project_id" => project["id"],
      "item_id" => item["id"],
      "issue_id" => content["id"],
      "issue_number" => content["number"],
      "issue_state" => content["state"],
      "repo" => get_in(content, ["repository", "nameWithOwner"]),
      "is_archived" => item["isArchived"],
      "status_field_id" => schema.status["id"],
      "status_option_id" => option_id(item["field_0"]),
      "agent_allowed_field_id" => schema.allowed["id"],
      "agent_allowed_option_id" => option_id(item["field_1"]),
      "project_fields" => context
    }
  end

  defp option_id(%{"optionId" => option_id}) when is_binary(option_id), do: option_id
  defp option_id(_value), do: nil

  defp build_issue(_item, _content, nil, _native_ref, _reasons, _in_scope), do: nil
  defp build_issue(_item, _content, _state, _native_ref, _reasons, false), do: nil

  defp build_issue(item, content, state, native_ref, reasons, true) do
    %Issue{
      id: item["id"],
      identifier: identifier(item["id"]),
      native_ref: native_ref,
      title: issue_title(content),
      description: content["body"],
      state: state,
      url: content["url"],
      labels: labels(content),
      assignee_id: content |> Map.get("assignees", []) |> List.first() |> assignee_login(),
      dispatchable: reasons == [],
      created_at: parse_datetime(content["createdAt"]),
      updated_at: parse_datetime(content["updatedAt"])
    }
  end

  defp issue_title(%{"__typename" => "Issue", "title" => title}), do: title
  defp issue_title(%{"__typename" => "DraftIssue"}), do: "[draft project item]"
  defp issue_title(%{"__typename" => "PullRequest"}), do: "[pull request project item]"
  defp issue_title(_content), do: "[unavailable issue content]"

  defp labels(content) do
    content
    |> Map.get("labels", [])
    |> Enum.map(fn label -> label["name"] |> String.trim() |> String.downcase() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp required_label_reasons(nil, _required), do: []

  defp required_label_reasons(issue, required) do
    labels = MapSet.new(issue.labels)

    if Enum.all?(required, &(String.downcase(String.trim(&1)) in labels)),
      do: [],
      else: ["missing_required_labels"]
  end

  defp identifier(id), do: "GHP-" <> Base.encode16(id, case: :lower)
  defp assignee_login(%{"login" => login}), do: login
  defp assignee_login(_assignee), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _value -> nil
    end
  end

  defp parse_datetime(_value), do: nil
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
