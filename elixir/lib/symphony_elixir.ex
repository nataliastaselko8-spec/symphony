defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  alias SymphonyElixir.GitHubProjects.Inspection

  @doc """
  Start the agent runtime in the current BEAM node.
  """
  @spec start_link() :: Supervisor.on_start()
  def start_link do
    with :ok <- Inspection.validate_runtime_workflow() do
      SymphonyElixir.AgentRuntimeSupervisor.start_link([])
    end
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.GitHubProjects.Inspection
  alias SymphonyElixir.Operator.Auth

  @dialyzer {:nowarn_function, start_burrito_cli: 0}

  @impl true
  def start(_type, _args) do
    if burrito_runtime?() do
      start_burrito_cli()
    else
      start_runtime()
    end
  end

  @doc false
  @spec start_runtime() :: Supervisor.on_start()
  def start_runtime do
    with :ok <- Inspection.validate_runtime_workflow() do
      start_supervisor()
    end
  end

  defp start_supervisor do
    :ok = SymphonyElixir.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.AgentRuntimeSupervisor,
      {Auth, name: Auth, settings: operator_settings()},
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  defp operator_settings do
    {:ok, settings} = Auth.from_config(SymphonyElixir.Config.settings!())
    settings
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp start_burrito_cli do
    Task.start_link(fn ->
      SymphonyElixir.CLI.main(
        plain_arguments(),
        &start_runtime/0
      )
    end)
  end

  defp burrito_runtime?, do: System.get_env("__BURRITO") == "1"

  defp plain_arguments, do: Enum.map(:init.get_plain_arguments(), &to_string/1)
end
