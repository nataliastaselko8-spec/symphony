defmodule SymphonyElixir.GitHubProjects.Delivery.Inspection do
  @moduledoc "One-shot delivery diagnostic; HTTP and an isolated credential cache only."

  alias SymphonyElixir.{Config, Config.Schema, Workflow}
  alias SymphonyElixir.GitHub.Credentials.Cache
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.Observation

  @spec run(Path.t(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def run(path, opts \\ []) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         {:ok, _observer} <- Config.delivery_observer_settings(settings),
         {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, cache} <- Cache.start_link(Keyword.put(Keyword.get(opts, :credentials_cache_options, []), :name, nil)) do
      try do
        Delivery.observe(settings, Keyword.put(opts, :credentials_cache, cache))
      after
        GenServer.stop(cache)
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_delivery_workflow}
    end
  end

  @spec exit_code({:ok, Observation.t()} | {:error, term()}) :: 0 | 1 | 2
  def exit_code({:error, _}), do: 1
  def exit_code({:ok, %Observation{complete: false}}), do: 1
  def exit_code({:ok, %Observation{reasons: ["manual_dev_validation_required"]}}), do: 0
  def exit_code({:ok, _}), do: 2

  @spec cli([String.t()], keyword()) :: {non_neg_integer(), String.t()}
  def cli(args, opts \\ []) do
    {options, rest, invalid} = OptionParser.parse(args, strict: [workflow: :string, help: :boolean])

    cond do
      options[:help] ->
        {0, "mix github_projects.delivery.inspect --workflow /controller/inspection.WORKFLOW.md"}

      rest != [] or invalid != [] or not is_binary(options[:workflow]) ->
        {1, "A single --workflow path is required"}

      true ->
        result = run(options[:workflow], opts)

        body =
          case result do
            {:ok, observation} -> observation
            {:error, reason} -> %{complete: false, execution_enabled: false, error: Atom.to_string(reason)}
          end

        {exit_code(result), Jason.encode!(body, pretty: true)}
    end
  end
end
