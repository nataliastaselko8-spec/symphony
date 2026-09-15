defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.GitHubProjects.Inspection
  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer, dry_run: :boolean]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          optional(:inspect_workflow) => (Path.t() -> {:ok, map()} | {:error, term()}),
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    main(args, fn -> Application.ensure_all_started(:symphony_elixir) end)
  end

  @doc false
  @spec main([String.t()], (-> ensure_started_result()) | deps()) :: no_return()
  def main(args, ensure_all_started) when is_function(ensure_all_started, 0) do
    main(args, runtime_deps(ensure_all_started))
  end

  def main(args, deps) when is_map(deps) do
    case evaluate(args, deps) do
      :ok ->
        wait_for_shutdown()

      {:inspection, report} ->
        IO.puts(Jason.encode!(report))
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:inspection, map()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        evaluate_workflow(Path.expand("WORKFLOW.md"), opts, deps)

      {opts, [workflow_path], []} ->
        evaluate_workflow(workflow_path, opts, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      with :ok <- Inspection.validate_runtime_workflow(expanded_path),
           :ok <- deps.set_workflow_file_path.(expanded_path) do
        start_workflow_runtime(expanded_path, deps)
      else
        {:error, :github_projects_execution_disabled} ->
          {:error, "github_projects execution is disabled; use --dry-run for read-only inspection"}

        {:error, _reason} ->
          {:error, "Failed to set workflow path"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  defp start_workflow_runtime(expanded_path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--dry-run | --logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps(ensure_all_started \\ fn -> Application.ensure_all_started(:symphony_elixir) end) do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: ensure_all_started
    }
  end

  defp evaluate_workflow(path, opts, deps) do
    if Keyword.get(opts, :dry_run, false) do
      inspect_workflow(path, opts, deps)
    else
      with :ok <- require_guardrails_acknowledgement(opts),
           :ok <- maybe_set_logs_root(opts, deps),
           :ok <- maybe_set_server_port(opts, deps) do
        run(path, deps)
      end
    end
  end

  defp inspect_workflow(path, opts, deps) do
    if Keyword.has_key?(opts, :logs_root) or Keyword.has_key?(opts, :port) do
      {:error, "--dry-run cannot be combined with --logs-root or --port"}
    else
      inspect_workflow = Map.get(deps, :inspect_workflow, &Inspection.run/1)

      case inspect_workflow.(Path.expand(path)) do
        {:ok, report} ->
          {:inspection, report}

        {:error, reason} ->
          {:error, "Project inspection failed: #{inspect(reason)}"}
      end
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
