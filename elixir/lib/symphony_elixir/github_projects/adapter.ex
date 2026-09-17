defmodule SymphonyElixir.GitHubProjects.Adapter do
  @moduledoc """
  GitHub Projects reads and controller-bound task tools. Live execution remains disabled.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHubProjects.{AgentTool, Client}
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
  def agent_tool_specs, do: AgentTool.specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)
end
