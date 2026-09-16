defmodule SymphonyElixir.DeliveryGate.Store do
  @moduledoc false

  @external_resource Path.expand("../../../priv/delivery_store.py", __DIR__)
  @script File.read!(@external_resource)
  @timeout 5_000

  @spec open(Path.t()) :: {:ok, port()} | {:error, atom()}
  def open(path) do
    with {:unix, :linux} <- :os.type(),
         python when is_binary(python) <- System.find_executable("python3") do
      port = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :exit_status, :use_stdio, {:args, ["-I", "-u", "-c", @script, path]}])

      case receive_reply(port) do
        {:ok, true} ->
          {:ok, port}

        {:error, _} = error ->
          close(port)
          error
      end
    else
      _ -> {:error, :linux_python_required}
    end
  end

  @spec request(port(), map()) :: {:ok, term()} | {:error, atom()}
  def request(port, command) do
    if Port.info(port) do
      Port.command(port, Jason.encode!(command))
      receive_reply(port)
    else
      {:error, :store_unavailable}
    end
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  @spec close(port()) :: :ok
  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp receive_reply(port) do
    receive do
      {^port, {:data, raw}} ->
        case Jason.decode(raw) do
          {:ok, %{"ok" => result}} -> {:ok, result}
          _ -> {:error, :store_operation_failed}
        end

      {^port, {:exit_status, _}} ->
        {:error, :store_unavailable}

      {:EXIT, ^port, _} ->
        {:error, :store_unavailable}
    after
      @timeout ->
        close(port)
        {:error, :store_timeout}
    end
  end
end
