defmodule SymphonyElixir.GitHubProjectsEntrypointTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "CLI main emits JSON and exits zero without entering the runtime wait loop" do
    code = """
    forbidden = fn -> raise "runtime started" end
    inspect = fn _path ->
      for name <- [SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator,
                   SymphonyElixir.WorkflowStore, SymphonyElixir.StatusDashboard] do
        if Process.whereis(name), do: raise("unexpected runtime process")
      end
      {:ok, %{"items" => [], "summary" => %{"total" => 0}}}
    end
    SymphonyElixir.CLI.main(["--dry-run"], %{inspect_workflow: inspect, ensure_all_started: forbidden})
    """

    assert {output, 0} = run_elixir(code)
    assert Jason.decode!(output) == %{"items" => [], "summary" => %{"total" => 0}}
  end

  test "CLI main exits one on failed inspection without emitting a successful report" do
    code = """
    inspect = fn _path -> {:error, :github_projects_forbidden} end
    SymphonyElixir.CLI.main(["--dry-run"], %{inspect_workflow: inspect})
    """

    assert {output, 1} = run_elixir(code)
    assert output =~ "Project inspection failed: :github_projects_forbidden"
    refute output =~ ~s("items")
  end

  test "all ordinary runtime entrypoints refuse Projects before configuring logs or starting supervisors", %{tmp_dir: root} do
    path = Path.join(root, "WORKFLOW.md")
    log_path = Path.join(root, "must-not-exist/runtime.log")
    File.write!(path, "---\ntracker:\n  kind: github_projects\n---\n")

    code = """
    System.delete_env("__BURRITO")
    Application.put_env(:symphony_elixir, :workflow_file_path, #{inspect(path)})
    Application.put_env(:symphony_elixir, :log_file, #{inspect(log_path)})
    expected = {:error, :github_projects_execution_disabled}
    ^expected = SymphonyElixir.Application.start_runtime()
    ^expected = SymphonyElixir.Application.start(:normal, [])
    ^expected = SymphonyElixir.start_link()
    {:error, {:symphony_elixir, _reason}} = Application.ensure_all_started(:symphony_elixir)
    for name <- [SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor,
                 SymphonyElixir.Orchestrator, SymphonyElixir.WorkflowStore,
                 SymphonyElixir.HttpServer, SymphonyElixir.StatusDashboard] do
      nil = Process.whereis(name)
    end
    false = File.exists?(#{inspect(log_path)})
    IO.puts("RUNTIME_REFUSED")
    """

    assert {output, 0} = run_elixir(code)
    assert output =~ "RUNTIME_REFUSED\n"
    refute File.exists?(log_path)
  end

  test "Burrito callback completes real inspection and HTTP startup without starting the runtime", %{tmp_dir: root} do
    path = Path.join(root, "WORKFLOW.md")
    workspace = Path.join(root, "must-not-be-created")

    File.write!(path, """
    ---
    tracker:
      kind: github_projects
      provider:
        token: fixture-token
    workspace:
      root: #{workspace}
    hooks:
      after_create: exit 97
      before_run: exit 97
      before_remove: exit 97
    codex:
      command: exit 97
    ---
    """)

    code = """
    Code.compiler_options(ignore_module_conflict: true)
    defmodule SymphonyElixir.GitHubProjects.Client do
      def validate_settings(_settings), do: :ok
      def inspect(_settings, _opts) do
        for name <- [SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator,
                     SymphonyElixir.WorkflowStore, SymphonyElixir.StatusDashboard] do
          nil = Process.whereis(name)
        end
        nil = Application.get_env(:symphony_elixir, :workflow_file_path)
        false = File.exists?(#{inspect(workspace)})
        true = Enum.any?(Application.started_applications(), fn {name, _, _} -> name == :req end)
        {:ok, %{"items" => [], "execution_enabled" => false}}
      end
    end
    System.put_env("__BURRITO", "1")
    {:ok, _pid} = SymphonyElixir.Application.start(:normal, [])
    Process.sleep(:infinity)
    """

    assert {output, 0} = run_burrito(code, ["--dry-run", path])
    assert Jason.decode!(output) == %{"items" => [], "execution_enabled" => false}
    refute File.exists?(workspace)
  end

  test "Burrito callback rejects malformed workflow through real inspection and exits one", %{tmp_dir: root} do
    path = Path.join(root, "WORKFLOW.md")
    File.write!(path, "---\ntracker: [\n---\nDO_NOT_PRINT_SECRET\n")

    code = """
    System.put_env("__BURRITO", "1")
    {:ok, _pid} = SymphonyElixir.Application.start(:normal, [])
    Process.sleep(:infinity)
    """

    assert {output, 1} = run_burrito(code, ["--dry-run", path])
    assert output =~ "Project inspection failed: :invalid_workflow"
    refute output =~ "DO_NOT_PRINT_SECRET"
  end

  defp run_burrito(code, plain_args) do
    executable = System.find_executable("erl") || raise "Erlang executable is required for entrypoint tests"
    eval = "application:ensure_all_started(elixir), 'Elixir.Code':eval_string(base64:decode(\"#{Base.encode64(code)}\"))."
    run_process(executable, ["-noshell", "+S", "2"] ++ code_paths() ++ ["-eval", eval, "-extra" | plain_args])
  end

  defp run_elixir(code) do
    executable = System.find_executable("elixir") || raise "Elixir executable is required for entrypoint tests"
    run_process(executable, ["--erl", "+S 2"] ++ code_paths() ++ ["-e", code])
  end

  defp code_paths do
    :code.get_path()
    |> Enum.flat_map(fn path -> ["-pa", path |> List.to_string() |> Path.expand()] end)
  end

  defp run_process(executable, args) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    try do
      collect_output(port, "")
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_output(port, output) do
    receive do
      {^port, {:data, data}} -> collect_output(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      15_000 -> flunk("entrypoint did not terminate: #{output}")
    end
  end
end
