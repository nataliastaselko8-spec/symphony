defmodule SymphonyElixir.DeliveryGate.Settings do
  @moduledoc "Controller-local storage contract, parsed without opening files or requesting credentials."

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.Credentials.Reference

  @spec from_config(Schema.t()) :: {:ok, map()} | {:error, atom()}
  def from_config(settings) do
    provider = settings.tracker.provider
    path = settings.delivery.state_path
    repo = provider["repo"]
    org = provider["organization"]
    project = provider["project_number"]

    cond do
      settings.tracker.kind != "github_projects" ->
        {:error, :delivery_requires_github_projects}

      not valid_scope?(org, repo, project) ->
        {:error, :invalid_delivery_scope}

      not valid_path?(path, settings.workspace.root) ->
        {:error, :invalid_delivery_state_path}

      true ->
        build_settings(settings)
    end
  end

  @spec compatible?(map(), map()) :: boolean()
  def compatible?(current, proposed), do: current == proposed

  defp build_settings(settings) do
    provider = settings.tracker.provider

    with {:ok, identity} <- credential_identity(provider) do
      contract = %{
        "fields" => provider["fields"],
        "states" => provider["states"],
        "allowed_value" => provider["agent_allowed_value"],
        "workspace_root" => settings.workspace.root,
        "active_states" => settings.tracker.active_states,
        "terminal_states" => settings.tracker.terminal_states,
        "ssh_hosts" => settings.worker.ssh_hosts,
        "identity" => identity
      }

      hash = :crypto.hash(:sha256, :erlang.term_to_binary(contract, [:deterministic])) |> Base.encode16(case: :lower)

      scope = %{
        "tracker_kind" => "github_projects",
        "organization" => String.downcase(provider["organization"]),
        "repo" => String.downcase(provider["repo"]),
        "project_number" => provider["project_number"],
        "base_branch" => settings.delivery.base_branch,
        "contract_hash" => hash
      }

      {:ok, %{path: settings.delivery.state_path, scope: scope}}
    end
  end

  defp credential_identity(%{"github_app" => _} = provider) do
    with {:ok, reference} <- Reference.new(provider, :projects_read) do
      {:ok, Map.take(reference, [:app_id, :installation_id, :client_id, :permissions])}
    end
  end

  defp credential_identity(_), do: {:ok, "inspection-token"}

  defp valid_scope?(org, repo, project) do
    is_binary(org) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9-]*$/, org) and
      is_binary(repo) and Regex.match?(~r/^[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+$/, repo) and
      String.downcase(hd(String.split(repo, "/"))) == String.downcase(org) and
      is_integer(project) and project > 0
  end

  defp valid_path?(path, root) do
    is_binary(path) and String.starts_with?(path, "/") and not String.starts_with?(path, "/mnt/") and
      Path.expand(path) == path and not String.contains?(path, ["\\", <<0>>]) and
      not String.starts_with?(path, String.trim_trailing(Path.expand(root), "/") <> "/") and
      path != Path.expand(root) and Path.basename(path) not in ["", ".", ".."]
  end
end
