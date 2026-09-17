defmodule SymphonyElixir.WorkerTransport do
  @moduledoc "Explicit PR-11 transport callbacks. Startup does not install or enable these callbacks."

  @spec callbacks(map(), (map() -> {:ok, map()} | {:error, term()})) :: keyword()
  def callbacks(binding, exchange) when is_function(exchange, 1) do
    [
      stop_verifier: fn worker -> stop(worker, binding, exchange) end,
      export_candidate: fn cycle, sha -> export(cycle, sha, binding, exchange) end
    ]
  end

  defp stop(worker, binding, exchange) do
    with %{interval: interval, handle: %{context: %{"cycle_id" => cycle}}} <- worker,
         true <- interval == binding["interval"] and cycle == binding["cycle"],
         {:ok, %{"phase" => "stopped"} = proof} <- safe_exchange(exchange, request(binding, "stop")),
         true <- matches?(proof, binding) do
      :stopped
    else
      _ -> :stop_unconfirmed
    end
  end

  defp export(cycle, sha, binding, exchange) do
    with %{"id" => id, "work" => %{"branch" => branch}} <- cycle,
         true <- id == binding["cycle"] and branch == binding["branch"],
         {:ok, %{"path" => path, "sha" => ^sha} = proof} when is_binary(path) <- safe_exchange(exchange, Map.put(request(binding, "export"), "sha", sha)),
         true <- matches?(proof, binding) do
      {:ok, path}
    else
      _ -> {:error, :worker_export_unconfirmed}
    end
  end

  defp request(binding, action), do: binding |> Map.take(~w(interval generation)) |> Map.put("action", action)
  defp matches?(proof, binding), do: Enum.all?(~w(cycle branch interval generation), &(is_binary(binding[&1]) and proof[&1] == binding[&1]))

  defp safe_exchange(exchange, request) do
    exchange.(request)
  rescue
    _ -> {:error, :worker_transport_unconfirmed}
  catch
    _, _ -> {:error, :worker_transport_unconfirmed}
  end

  @spec exchange(String.t(), String.t(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def exchange(script, config, request, timeout \\ 95_000) do
    with {:unix, :linux} <- :os.type(), python when is_binary(python) <- System.find_executable("python3") do
      port = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :exit_status, :use_stdio, {:args, ["-I", "-B", script, "--config", config]}])

      try do
        Port.command(port, Jason.encode!(request))

        receive do
          {^port, {:data, raw}} -> decode(raw)
          {^port, {:exit_status, _}} -> {:error, :worker_transport_unconfirmed}
        after
          timeout -> {:error, :worker_transport_timeout}
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    else
      _ -> {:error, :linux_python_required}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"ok" => proof}} when is_map(proof) -> {:ok, proof}
      _ -> {:error, :worker_transport_unconfirmed}
    end
  end
end
