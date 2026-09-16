defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.GitHub.Credentials.Cache

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    credentials_cache_name = Keyword.get(opts, :credentials_cache_name, Cache)
    config = Keyword.get_lazy(opts, :config, &Config.settings!/0)
    delivery = if config.tracker.kind == "github_projects", do: Keyword.get(opts, :delivery_name, DeliveryRuntime)
    gate = Keyword.get(opts, :gate_name, DeliveryGate)
    gate_options = [name: gate, settings: elem(Config.delivery_settings(config), 1)]
    gate_children = if delivery, do: [{DeliveryGate, gate_options}], else: []

    runtime_children =
      if delivery do
        [
          {DeliveryRuntime,
           [name: delivery, gate: gate, config: config, task_supervisor: task_supervisor_name] ++
             Keyword.get(opts, :delivery_options, [])}
        ]
      else
        []
      end

    orchestrator_options = [name: orchestrator_name, task_supervisor: task_supervisor_name, delivery_runtime: delivery]

    children =
      [{Cache, name: credentials_cache_name}] ++
        gate_children ++
        [
          Supervisor.child_spec(
            {Task.Supervisor, name: task_supervisor_name},
            id: task_supervisor_name
          )
        ] ++
        runtime_children ++
        [
          Supervisor.child_spec(
            {SymphonyElixir.Orchestrator, orchestrator_options},
            id: orchestrator_name
          )
        ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
