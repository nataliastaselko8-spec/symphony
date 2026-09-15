defmodule SymphonyElixir.GitHubProjectsInspectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI
  alias SymphonyElixir.GitHubProjects.Inspection

  @moduletag :tmp_dir

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  setup %{tmp_dir: root} do
    path = Path.join(root, "WORKFLOW.md")
    %{path: path}
  end

  @tag :tmp_dir
  test "inspection reads an explicit workflow without changing runtime configuration or workspaces", %{path: path} do
    root = Path.dirname(path)
    workspace = Path.join(root, "must-not-be-created")
    previous_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_logs = Application.get_env(:symphony_elixir, :log_file)
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    File.write!(path, workflow(workspace))

    assert {:ok, %{"items" => []}} =
             Inspection.run(path,
               inspect_project: fn settings, _opts ->
                 assert settings.kind == "github_projects"
                 assert settings.provider["organization"] == "example-org"
                 {:ok, %{"items" => []}}
               end
             )

    assert Application.get_env(:symphony_elixir, :workflow_file_path) == previous_path
    assert Application.get_env(:symphony_elixir, :log_file) == previous_logs
    assert Process.whereis(SymphonyElixir.Supervisor) == supervisor
    refute File.exists?(workspace)
  end

  @tag :tmp_dir
  test "inspection preserves existing workspaces with Done-shaped sentinel content", %{path: path} do
    workspace = Path.join(Path.dirname(path), "existing-workspace")
    File.mkdir_p!(workspace)
    sentinel = Path.join(workspace, "unpublished-work")
    File.write!(sentinel, "preserve")
    File.write!(path, workflow(workspace))

    assert {:ok, _report} =
             Inspection.run(path,
               inspect_project: fn _settings, _opts -> {:ok, %{"items" => [%{"status" => "Done"}]}} end
             )

    assert File.read!(sentinel) == "preserve"
  end

  @tag :tmp_dir
  test "inspection rejects other providers and malformed workflows before calling reader", %{path: path} do
    inspect_project = fn _, _ -> flunk("reader must not be called") end
    assert {:error, :workflow_not_found} = Inspection.run(path, inspect_project: inspect_project)

    File.write!(path, "---\ntracker:\n  kind: memory\n---\n")
    assert {:error, :dry_run_requires_github_projects} = Inspection.run(path, inspect_project: inspect_project)

    File.write!(path, "---\ntracker: [\n---\nsecret-do-not-print\n")
    assert {:error, :invalid_workflow} = Inspection.run(path, inspect_project: inspect_project)

    File.write!(path, workflow("/unused") |> String.replace("kind: github_projects", "kind: github_projects\npolling:\n  interval_ms: nope"))
    assert {:error, :invalid_workflow_config} = Inspection.run(path, inspect_project: inspect_project)
  end

  @tag :tmp_dir
  test "inspection forwards safe reader failures without converting them into an empty successful queue", %{path: path} do
    File.write!(path, workflow("/unused"))

    assert {:error, :github_projects_forbidden} =
             Inspection.run(path, inspect_project: fn _, _ -> {:error, :github_projects_forbidden} end)
  end

  @tag :tmp_dir
  test "ordinary CLI refuses Projects even with acknowledgement before setting workflow or starting runtime", %{path: path} do
    File.write!(path, "---\ntracker:\n  kind: github_projects\n---\n")

    assert {:error, message} = CLI.evaluate([@ack_flag, path], forbidden_runtime_deps())
    assert message =~ "execution is disabled"
    assert message =~ "--dry-run"
  end

  test "dry-run returns a finite result without acknowledgement or runtime dependencies" do
    deps =
      Map.put(forbidden_runtime_deps(), :inspect_workflow, fn path ->
        assert path == Path.expand("EXPLICIT.md")
        {:ok, %{"items" => [], "summary" => %{"total" => 0}}}
      end)

    assert {:inspection, %{"items" => []}} = CLI.evaluate(["--dry-run", "EXPLICIT.md"], deps)
  end

  test "dry-run rejects runtime options before invoking either path" do
    deps = Map.put(forbidden_runtime_deps(), :inspect_workflow, fn _ -> flunk("no inspection") end)

    assert {:error, message} = CLI.evaluate(["--dry-run", "--logs-root", "logs"], deps)
    assert message =~ "cannot be combined"
    assert {:error, _} = CLI.evaluate(["--dry-run", "--port", "4000"], deps)
  end

  test "dry-run failures remain failures and do not start the runtime" do
    deps = Map.put(forbidden_runtime_deps(), :inspect_workflow, fn _ -> {:error, :github_projects_forbidden} end)

    assert {:error, "Project inspection failed: :github_projects_forbidden"} =
             CLI.evaluate(["--dry-run"], deps)
  end

  test "default CLI inspection rejects unsupported workflows without starting runtime", %{path: path} do
    File.write!(path, "---\ntracker:\n  kind: memory\n---\n")

    assert {:error, "Project inspection failed: :dry_run_requires_github_projects"} =
             CLI.evaluate(["--dry-run", path], forbidden_runtime_deps())
  end

  test "failed HTTP dependency startup prevents reading and redacts its internal reason", %{path: path} do
    File.write!(path, workflow("/unused"))
    parent = self()

    assert {:error, :inspection_http_start_failed} =
             Inspection.run(path,
               ensure_http_started: fn ->
                 send(parent, :http_start_attempted)
                 {:error, {:dependency_failed, "DO_NOT_PRINT_SECRET"}}
               end,
               inspect_project: fn _, _ -> flunk("reader must not run without HTTP dependencies") end
             )

    assert_received :http_start_attempted
  end

  defp forbidden_runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: fn _ -> flunk("workflow must not be changed") end,
      set_logs_root: fn _ -> flunk("logs must not be configured") end,
      set_server_port_override: fn _ -> flunk("server must not be configured") end,
      ensure_all_started: fn -> flunk("runtime must not start") end
    }
  end

  defp workflow(workspace) do
    """
    ---
    tracker:
      kind: github_projects
      provider:
        organization: example-org
        project_number: 1
        repo: example-org/example-repo
        token: fixture-token
        fields:
          status: Status
          agent_allowed: Agent allowed
        agent_allowed_value: "yes"
        states:
          ready: Ready for agent
          working: Agent working
          blocked: Needs human decision
          handoff: PR ready
      active_states: [Ready for agent, Agent working]
      terminal_states: [Done]
    workspace:
      root: #{workspace}
    hooks:
      after_create: exit 97
      before_run: exit 97
      after_run: exit 97
      before_remove: exit 97
    codex:
      command: exit 97
    ---
    This prompt must not execute.
    """
  end
end
