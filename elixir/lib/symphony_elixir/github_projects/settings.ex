defmodule SymphonyElixir.GitHubProjects.Settings do
  @moduledoc false

  @default_states %{
    "ready" => "Ready for agent",
    "working" => "Agent working",
    "blocked" => "Needs human decision",
    "handoff" => "PR ready"
  }

  @spec parse(map()) :: {:ok, map()} | {:error, atom()}
  def parse(%{provider: provider} = tracker) when is_map(provider) do
    fields = Map.get(provider, "fields", %{})
    states = Map.get(provider, "states", @default_states)
    active = Map.get(tracker, :active_states, [])
    terminal = Map.get(tracker, :terminal_states, [])
    token = resolve_token(Map.get(provider, "token", "$GITHUB_TOKEN"))

    with :ok <- validate_scope(provider, token),
         :ok <- validate_policy(provider, fields, states, active, terminal) do
      {:ok,
       %{
         endpoint: "https://api.github.com/graphql",
         token: token,
         organization: provider["organization"],
         project_number: provider["project_number"],
         repo: provider["repo"],
         fields: Map.merge(%{"status" => "Status", "agent_allowed" => "Agent allowed"}, fields),
         allowed_value: Map.get(provider, "agent_allowed_value", "yes"),
         states: states,
         active_states: active,
         terminal_states: terminal,
         required_labels: Map.get(tracker, :required_labels, []),
         item_ids: Map.get(provider, "item_ids"),
         context_fields: Map.get(provider, "context_fields", [])
       }}
    end
  end

  def parse(_tracker), do: {:error, :invalid_github_projects_provider}

  defp validate_scope(provider, token) do
    cond do
      not valid_name?(provider["organization"]) ->
        {:error, :invalid_github_projects_organization}

      not (is_integer(provider["project_number"]) and provider["project_number"] > 0) ->
        {:error, :invalid_github_projects_number}

      not valid_repo?(provider["repo"], provider["organization"]) ->
        {:error, :invalid_github_projects_repo}

      not present?(token) ->
        {:error, :missing_github_projects_token}

      true ->
        :ok
    end
  end

  defp validate_policy(provider, fields, states, active, terminal) do
    cond do
      not valid_fields?(fields) ->
        {:error, :invalid_github_projects_fields}

      not present?(Map.get(provider, "agent_allowed_value", "yes")) ->
        {:error, :invalid_github_projects_allowed_value}

      not valid_states?(states, active, terminal) ->
        {:error, :invalid_github_projects_states}

      not valid_optional_list?(provider, "item_ids") ->
        {:error, :invalid_github_projects_item_ids}

      not valid_optional_list?(provider, "context_fields") ->
        {:error, :invalid_github_projects_context_fields}

      true ->
        :ok
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker) do
    provider = Map.get(tracker, :provider, %{})

    reference =
      case provider do
        %{"token" => "$" <> name} -> if valid_env_name?(name), do: [name], else: []
        _ -> []
      end

    Enum.uniq(["GITHUB_TOKEN", "GH_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_ENTERPRISE_TOKEN" | reference])
  end

  defp resolve_token("$" <> name) do
    if valid_env_name?(name), do: System.get_env(name)
  end

  defp resolve_token(token) when is_binary(token), do: token
  defp resolve_token(_token), do: nil

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_name?(name) when is_binary(name),
    do: String.match?(name, ~r/^[A-Za-z0-9][A-Za-z0-9-]*$/)

  defp valid_name?(_name), do: false

  defp valid_repo?(repo, organization) when is_binary(repo) do
    case String.split(repo, "/") do
      [owner, name] ->
        String.downcase(owner) == String.downcase(organization) and
          String.match?(name, ~r/^[A-Za-z0-9_.-]+$/) and name not in [".", ".."]

      _ ->
        false
    end
  end

  defp valid_repo?(_repo, _organization), do: false

  defp valid_fields?(fields) when is_map(fields) do
    status = Map.get(fields, "status", "Status")
    allowed = Map.get(fields, "agent_allowed", "Agent allowed")
    present?(status) and present?(allowed) and status != allowed
  end

  defp valid_fields?(_fields), do: false

  defp valid_states?(states, active, terminal) when is_map(states) do
    roles = Enum.map(["ready", "working", "blocked", "handoff"], &states[&1])

    nonempty_string_list?(active) and nonempty_string_list?(terminal) and
      valid_roles?(roles) and
      Enum.all?([states["ready"], states["working"]], &(&1 in active)) and
      Enum.all?([states["blocked"], states["handoff"]], &(&1 not in active and &1 not in terminal)) and
      Enum.all?(active, &(&1 not in terminal))
  end

  defp valid_states?(_states, _active, _terminal), do: false

  defp nonempty_string_list?(list), do: string_list?(list) and list != []
  defp valid_roles?(roles), do: Enum.all?(roles, &present?/1) and length(Enum.uniq(roles)) == 4

  defp valid_optional_list?(provider, key) do
    not Map.has_key?(provider, key) or string_list?(provider[key])
  end

  defp string_list?(list) when is_list(list), do: Enum.all?(list, &present?/1)
  defp string_list?(_list), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
