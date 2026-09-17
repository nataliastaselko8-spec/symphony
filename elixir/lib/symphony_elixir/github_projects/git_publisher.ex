defmodule SymphonyElixir.GitHubProjects.GitPublisher do
  @moduledoc "Linux controller publisher. The exporter supplies a controller-owned immutable bundle, never a worker path."
  alias SymphonyElixir.GitHub.Credentials
  @external_resource Path.expand("../../../priv/git_publisher.py", __DIR__)
  @script File.read!(@external_resource)

  @spec candidate(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def candidate(settings, cycle, effect, opts) do
    case opts[:export_candidate] do
      exporter when is_function(exporter, 2) ->
        with {:ok, path} <- exporter.(cycle, effect["payload"]["sha"]), do: verify_candidate(path, settings, cycle, effect, opts)

      _ ->
        {:error, :candidate_transport_required}
    end
  end

  defp verify_candidate(path, settings, cycle, effect, opts) do
    command = %{
      "bundle" => path,
      "sha" => effect["payload"]["sha"],
      "base_sha" => Keyword.fetch!(opts, :base_sha),
      "previous_sha" => cycle["work"]["head_sha"],
      "branch" => cycle["work"]["branch"],
      "repo" => settings.repo,
      "token" => nil,
      "send" => false,
      "digest" => nil
    }

    with {:ok, proof} <- run(command), do: {:ok, %{command: command, proof: proof}}
  end

  @spec push(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def push(settings, candidate, opts) do
    with {:ok, reference} <- Credentials.reference(settings.tracker.provider, :contents_write),
         {:ok, token} <- Credentials.token(reference, opts) do
      run(Map.merge(candidate.command, %{"token" => token, "send" => true, "digest" => candidate.proof["digest"]}))
    end
  end

  @spec run(map()) :: {:ok, map()} | {:error, atom()}
  def run(command) do
    with {:unix, :linux} <- :os.type(), python when is_binary(python) <- System.find_executable("python3") do
      port = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :exit_status, :use_stdio, {:args, ["-I", "-u", "-c", @script]}])
      exchange(port, command, 300_000)
    else
      _ -> {:error, :linux_python_required}
    end
  end

  @doc false
  @spec exchange(port(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def exchange(port, command, timeout) do
    Port.command(port, Jason.encode!(command))

    receive do
      {^port, {:data, raw}} -> decode(raw)
      {^port, {:exit_status, _}} -> {:error, :git_publication_unconfirmed}
    after
      timeout -> {:error, :git_publication_timeout}
    end
  after
    if Port.info(port), do: Port.close(port)
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"ok" => proof}} when is_map(proof) -> {:ok, proof}
      _ -> {:error, :git_publication_unconfirmed}
    end
  end
end
