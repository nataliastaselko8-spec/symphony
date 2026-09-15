defmodule SymphonyElixir.GitHubProjects.Inspection do
  @moduledoc """
  Finite, read-only Project inspection without starting the agent runtime.
  """

  alias SymphonyElixir.{Config, Config.Schema, Workflow}
  alias SymphonyElixir.GitHubProjects.Client

  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, opts \\ []) do
    with {:ok, workflow} <- load_workflow(path),
         :ok <- require_projects_tracker(workflow),
         {:ok, settings} <- parse_settings(workflow.config),
         :ok <- Config.validate_settings(settings),
         :ok <- start_http(opts) do
      inspect_project = Keyword.get(opts, :inspect_project, &Client.inspect/2)
      inspect_project.(settings.tracker, Keyword.drop(opts, [:inspect_project, :ensure_http_started]))
    end
  end

  @doc false
  @spec validate_runtime_workflow(Path.t()) :: :ok | {:error, :github_projects_execution_disabled}
  def validate_runtime_workflow(path \\ Workflow.workflow_file_path()) do
    case Workflow.load(path) do
      {:ok, %{config: %{"tracker" => %{"kind" => "github_projects"}}}} ->
        {:error, :github_projects_execution_disabled}

      _ ->
        :ok
    end
  end

  @doc false
  @spec validate_runtime_settings(Schema.t()) :: :ok | {:error, :github_projects_execution_disabled}
  def validate_runtime_settings(%{tracker: %{kind: "github_projects"}}),
    do: {:error, :github_projects_execution_disabled}

  def validate_runtime_settings(_settings), do: :ok

  defp load_workflow(path) do
    case Workflow.load(path) do
      {:ok, workflow} -> {:ok, workflow}
      {:error, {:missing_workflow_file, _, _}} -> {:error, :workflow_not_found}
      {:error, _} -> {:error, :invalid_workflow}
    end
  end

  defp require_projects_tracker(%{config: %{"tracker" => %{"kind" => "github_projects"}}}), do: :ok
  defp require_projects_tracker(_workflow), do: {:error, :dry_run_requires_github_projects}

  defp parse_settings(config) do
    case Schema.parse(config) do
      {:ok, settings} -> {:ok, settings}
      {:error, _} -> {:error, :invalid_workflow_config}
    end
  end

  defp start_http(opts) do
    ensure_http_started = Keyword.get(opts, :ensure_http_started, fn -> Application.ensure_all_started(:req) end)

    case ensure_http_started.() do
      {:ok, _apps} -> :ok
      {:error, _reason} -> {:error, :inspection_http_start_failed}
    end
  end
end
