defmodule SymphonyElixir.Runtime.Activation do
  @moduledoc "Pinned launcher activation shared by all Projects entry points. Never a task tool."
  alias SymphonyElixir.{Config.Schema, WorkerTransport, Workflow}

  @spec validate_workflow(Path.t()) :: :ok | {:error, atom()}
  def validate_workflow(path) do
    with config when is_binary(config) <- System.get_env("SYMPHONY_RUNTIME_CONFIG"),
         helper when is_binary(helper) <- System.get_env("SYMPHONY_RUNTIME_HELPER"),
         true <- Path.type(config) == :absolute and Path.type(helper) == :absolute,
         {:ok, proof} <- WorkerTransport.exchange(helper, config, %{"action" => "validate", "workflow" => Path.expand(path)}),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == proof["workflow_sha256"],
         {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         true <- settings.tracker.provider["repo"] == proof["repo"] do
      activation = %{helper: helper, config: config, proof: proof, settings: settings}
      Application.put_env(:symphony_elixir, :runtime_activation, activation)
      :ok
    else
      _ -> invalid()
    end
  end

  @spec validate_settings(Schema.t()) :: :ok | {:error, atom()}
  def validate_settings(settings) do
    case current() do
      %{settings: ^settings, proof: proof} ->
        with {:ok, raw} <- File.read(proof["workflow"]), true <- hash(raw) == proof["workflow_sha256"], do: :ok, else: (_ -> invalid())

      _ ->
        invalid()
    end
  end

  @spec current() :: map() | nil
  def current, do: Application.get_env(:symphony_elixir, :runtime_activation)

  defp invalid do
    Application.delete_env(:symphony_elixir, :runtime_activation)
    if pid = Process.whereis(SymphonyElixir.DeliveryRuntime), do: send(pid, :runtime_activation_invalid)
    {:error, :github_projects_execution_disabled}
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
