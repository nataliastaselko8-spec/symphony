defmodule SymphonyElixir.GitHubProjects.Adapter do
  @moduledoc """
  Read-only GitHub Projects tracker. Execution is disabled until rollout gates exist.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings), do: Client.validate_settings(tracker_settings)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: Client.fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids), do: Client.fetch_issues_by_ids(ids)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: []
end
