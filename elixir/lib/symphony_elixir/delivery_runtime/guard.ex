defmodule SymphonyElixir.DeliveryRuntime.Guard do
  @moduledoc "Fail closed at runner, hook, reload and cleanup boundaries."
  alias SymphonyElixir.{Config, DeliveryRuntime}
  alias SymphonyElixir.DeliveryRuntime.HookContext

  @spec projects?() :: boolean()
  def projects?, do: Config.settings!().tracker.kind == "github_projects"

  @spec check(map() | nil, atom()) :: :ok | {:error, atom()}
  def check(handle, mode \\ :continue)
  @spec check(map() | nil, atom()) :: :ok | {:error, atom()}
  def check(nil, _), do: if(projects?(), do: {:error, :delivery_permit_required}, else: :ok)
  def check(handle, mode), do: DeliveryRuntime.check(handle, mode)

  @spec command(String.t(), map() | nil) :: {:ok, String.t()} | {:error, atom()}
  def command(command, nil), do: {:ok, command}

  def command(command, handle) do
    with {:ok, prefix} <- HookContext.shell_prefix(handle.context), do: {:ok, prefix <> command}
  end

  @spec cleanup(String.t()) :: :ok | {:error, atom()}
  def cleanup(path) do
    if projects?(), do: DeliveryRuntime.cleanup(DeliveryRuntime, path), else: :ok
  catch
    :exit, _ -> {:error, :delivery_runtime_unavailable}
  end

  @spec reload(Config.Schema.t(), Config.Schema.t()) :: :ok | {:error, atom()}
  def reload(previous, proposed) do
    if previous.tracker.kind == "github_projects" do
      DeliveryRuntime.check_settings(DeliveryRuntime, proposed)
    else
      :ok
    end
  catch
    :exit, _ -> {:error, :delivery_runtime_unavailable}
  end
end
