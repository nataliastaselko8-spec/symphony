defmodule SymphonyElixir.GitHub.Credentials.Reference do
  @moduledoc """
  Immutable controller credential identity. It contains neither a key nor a token.
  """

  @derive {Inspect, only: [:app_id, :installation_id, :repo, :profile]}
  @enforce_keys [:app_id, :installation_id, :private_key_path, :repo, :profile, :permissions]
  defstruct [
    :app_id,
    :client_id,
    :installation_id,
    :private_key_path,
    :repo,
    :organization,
    :project_number,
    :profile,
    :permissions
  ]

  @type t :: %__MODULE__{
          app_id: String.t(),
          client_id: String.t() | nil,
          installation_id: String.t(),
          private_key_path: String.t(),
          repo: String.t(),
          organization: String.t() | nil,
          project_number: pos_integer() | nil,
          profile: atom(),
          permissions: %{String.t() => String.t()}
        }

  @profiles %{
    projects_write: %{"organization_projects" => "write", "issues" => "read", "metadata" => "read"},
    publication: %{"issues" => "write", "pull_requests" => "write", "contents" => "read", "metadata" => "read"},
    projects_read: %{"organization_projects" => "read", "issues" => "read", "contents" => "read", "metadata" => "read"},
    delivery_read: %{"actions" => "read", "pull_requests" => "read", "contents" => "read", "metadata" => "read"},
    github: %{"issues" => "write", "pull_requests" => "write", "contents" => "read", "metadata" => "read"},
    contents_write: %{"contents" => "write", "metadata" => "read"}
  }

  @spec new(map(), atom()) :: {:ok, t()} | {:error, atom()}
  def new(provider, profile) when is_map(provider) do
    with :ok <- validate_provider(provider),
         {:ok, app} <- app_settings(provider["github_app"]),
         {:ok, permissions} <- permissions(profile),
         {:ok, repo, organization, project_number} <- scope(provider, profile) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(app, %{
           repo: repo,
           organization: organization,
           project_number: project_number,
           profile: profile,
           permissions: permissions
         })
       )}
    end
  end

  def new(_provider, _profile), do: {:error, :invalid_github_app_config}

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(provider) do
    references =
      provider
      |> Map.get("github_app", %{})
      |> environment_references()

    Enum.uniq([
      "SYMPHONY_GITHUB_APP_ID",
      "SYMPHONY_GITHUB_APP_CLIENT_ID",
      "SYMPHONY_GITHUB_INSTALLATION_ID",
      "SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH" | references
    ])
  end

  defp validate_provider(provider) do
    cond do
      Map.has_key?(provider, "token") ->
        {:error, :mixed_github_credentials}

      provider["api_url"] not in [nil, "https://api.github.com", "https://api.github.com/"] ->
        {:error, :invalid_github_app_endpoint}

      true ->
        :ok
    end
  end

  defp app_settings(app) when is_map(app) do
    app_id = identifier(resolve(app["app_id"]))
    installation_id = identifier(resolve(app["installation_id"]))
    key_path = resolve(app["private_key_path"])
    client_id = resolve(app["client_id"])

    cond do
      is_nil(app_id) ->
        {:error, :invalid_github_app_id}

      is_nil(installation_id) ->
        {:error, :invalid_github_installation_id}

      not absolute_path?(key_path) ->
        {:error, :invalid_github_app_key_path}

      not valid_client_id?(app, client_id) ->
        {:error, :invalid_github_app_client_id}

      true ->
        {:ok, %{app_id: app_id, client_id: client_id, installation_id: installation_id, private_key_path: key_path}}
    end
  end

  defp app_settings(_app), do: {:error, :invalid_github_app_config}

  defp permissions(profile) do
    case Map.fetch(@profiles, profile) do
      {:ok, permissions} -> {:ok, permissions}
      :error -> {:error, :invalid_github_credential_profile}
    end
  end

  defp scope(provider, profile) do
    repo = resolve(provider["repo"])
    organization = resolve(provider["organization"])
    number = provider["project_number"]

    cond do
      not valid_repo?(repo) -> {:error, :invalid_github_credential_repo}
      not valid_organization?(repo, organization, profile) -> {:error, :invalid_github_credential_organization}
      not valid_project_number?(number, profile) -> {:error, :invalid_github_credential_project}
      true -> {:ok, repo, organization, number}
    end
  end

  defp valid_repo?(repo) when is_binary(repo) do
    String.match?(repo, ~r/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/) and
      List.last(String.split(repo, "/")) not in [".", ".."]
  end

  defp valid_repo?(_repo), do: false

  defp valid_organization?(_repo, nil, profile), do: profile not in [:projects_read, :projects_write]

  defp valid_organization?(repo, organization, _profile) when is_binary(organization),
    do: String.downcase(hd(String.split(repo, "/"))) == String.downcase(organization)

  defp valid_organization?(_repo, _organization, _profile), do: false

  defp valid_project_number?(nil, profile), do: profile not in [:projects_read, :projects_write]
  defp valid_project_number?(number, _profile), do: is_integer(number) and number > 0

  defp absolute_path?(path) when is_binary(path),
    do: Path.type(path) == :absolute and String.trim(path) != "" and not String.contains?(path, <<0>>)

  defp absolute_path?(_path), do: false

  defp valid_client_id?(app, nil), do: not Map.has_key?(app, "client_id")
  defp valid_client_id?(_app, value) when is_binary(value), do: String.match?(value, ~r/^[A-Za-z0-9_.-]+$/)
  defp valid_client_id?(_app, _value), do: false

  defp identifier(value) when is_integer(value) and value > 0, do: Integer.to_string(value)

  defp identifier(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> Integer.to_string(number)
      _value -> nil
    end
  end

  defp identifier(_value), do: nil

  defp resolve("$" <> name) do
    if valid_env_name?(name), do: System.get_env(name)
  end

  defp resolve(value), do: value

  defp environment_references(app) when is_map(app) do
    app
    |> Map.take(["app_id", "client_id", "installation_id", "private_key_path"])
    |> Map.values()
    |> Enum.flat_map(fn
      "$" <> name -> if valid_env_name?(name), do: [name], else: []
      _value -> []
    end)
  end

  defp environment_references(_app), do: []
  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
end
