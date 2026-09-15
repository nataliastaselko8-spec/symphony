defmodule SymphonyElixir.GitHubProjects.Schema do
  @moduledoc false

  @context_types ["TEXT", "NUMBER", "DATE", "SINGLE_SELECT", "ITERATION"]

  @spec resolve([map()], map()) :: {:ok, map()} | {:error, term()}
  def resolve(fields, settings) do
    with :ok <- validate_fields(fields),
         {:ok, status} <- required_field(fields, settings.fields["status"], :status),
         {:ok, allowed} <- required_field(fields, settings.fields["agent_allowed"], :agent_allowed),
         :ok <- validate_status_options(status, settings),
         {:ok, allow_option} <- option(allowed, settings.allowed_value, :agent_allowed) do
      {context, diagnostics} = context_fields(fields, settings.context_fields)

      {:ok,
       %{
         status: status,
         allowed: allowed,
         allow_option: allow_option,
         context: context,
         diagnostics: diagnostics
       }}
    end
  end

  @spec report(map()) :: map()
  def report(schema) do
    %{
      "status" => field_report(schema.status),
      "agent_allowed" => field_report(schema.allowed),
      "agent_allowed_option_id" => schema.allow_option["id"],
      "context_fields" => Enum.map(schema.context, &field_report/1)
    }
  end

  defp validate_fields(fields) do
    ids = Enum.map(fields, & &1["id"])

    if Enum.all?(fields, &(present?(&1["id"]) and present?(&1["name"]) and present?(&1["dataType"]))) and
         length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :github_projects_invalid_schema}
    end
  end

  defp required_field(fields, name, role) do
    case Enum.filter(fields, &(&1["name"] == name)) do
      [] ->
        {:error, {:github_projects_missing_field, role}}

      [%{"__typename" => "ProjectV2SingleSelectField", "dataType" => "SINGLE_SELECT"} = field] ->
        if valid_options?(field["options"]),
          do: {:ok, field},
          else: {:error, {:github_projects_invalid_options, role}}

      [_field] ->
        {:error, {:github_projects_wrong_field_type, role}}

      _fields ->
        {:error, {:github_projects_ambiguous_field, role}}
    end
  end

  defp validate_status_options(status, settings) do
    names = Enum.uniq(settings.active_states ++ settings.terminal_states ++ Map.values(settings.states))

    Enum.reduce_while(names, :ok, fn name, :ok ->
      case option(status, name, :status) do
        {:ok, _option} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp option(field, name, role) do
    case Enum.filter(field["options"], &(&1["name"] == name)) do
      [option] -> {:ok, option}
      [] -> {:error, {:github_projects_missing_option, role}}
      _options -> {:error, {:github_projects_ambiguous_option, role}}
    end
  end

  defp context_fields(fields, names) do
    Enum.reduce(Enum.uniq(names), {[], []}, fn name, {selected, diagnostics} ->
      case Enum.filter(fields, &(&1["name"] == name)) do
        [field] ->
          add_context_field(field, name, selected, diagnostics)

        [] ->
          {selected, diagnostics ++ [diagnostic("missing_context_field", name)]}

        _fields ->
          {selected, diagnostics ++ [diagnostic("ambiguous_context_field", name)]}
      end
    end)
  end

  defp add_context_field(field, name, selected, diagnostics) do
    if supported_context?(field),
      do: {selected ++ [field], diagnostics},
      else: {selected, diagnostics ++ [diagnostic("unsupported_context_field", name)]}
  end

  defp supported_context?(field) do
    field["dataType"] in @context_types and
      (field["dataType"] != "SINGLE_SELECT" or valid_options?(field["options"]))
  end

  defp valid_options?(options) when is_list(options) do
    ids = Enum.map(options, fn option -> if is_map(option), do: option["id"] end)

    Enum.all?(options, fn
      option when is_map(option) -> present?(option["id"]) and present?(option["name"])
      _option -> false
    end) and length(ids) == length(Enum.uniq(ids))
  end

  defp valid_options?(_options), do: false

  defp field_report(field), do: Map.take(field, ["id", "name", "dataType", "options"])
  defp diagnostic(code, name), do: %{"code" => code, "field" => name}
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
