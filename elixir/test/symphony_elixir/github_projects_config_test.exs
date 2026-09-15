defmodule SymphonyElixir.GitHubProjectsConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubProjects.Adapter

  test "Project provider settings remain separate from repository issue settings" do
    provider = %{
      "organization" => "example-org",
      "project_number" => 1,
      "repo" => "example-org/example-repo",
      "token" => "$EXAMPLE_PROJECT_TOKEN",
      "item_ids" => ["PVTI_example"],
      "fields" => %{"status" => "Status", "agent_allowed" => "Agent allowed"}
    }

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "github_projects",
                 "provider" => provider,
                 "active_states" => ["Ready for agent", "Agent working"],
                 "terminal_states" => ["Done"]
               }
             })

    assert settings.tracker.provider == provider
    assert settings.tracker.api_key == nil
    assert settings.tracker.active_states == ["Ready for agent", "Agent working"]
    assert {:ok, Adapter} = Tracker.adapter_for_kind("github_projects")
    assert {:ok, SymphonyElixir.GitHub.Adapter} = Tracker.adapter_for_kind("github")
  end

  test "a rejected Project path switch preserves the accepted relative workspace root" do
    original_path = Workflow.workflow_file_path()
    write_workflow_file!(original_path, workspace_root: "relative-workspaces")
    original_root = Config.local_workspace_root()
    candidate = Path.join([Path.dirname(original_path), "another-directory", "WORKFLOW.md"])
    File.mkdir_p!(Path.dirname(candidate))
    File.write!(candidate, "---\ntracker:\n  kind: github_projects\n---\n")

    assert {:error, :github_projects_execution_disabled} =
             Workflow.set_workflow_file_path(candidate)

    assert Workflow.workflow_file_path() == original_path
    assert Config.local_workspace_root() == original_root
    assert Config.settings!().tracker.kind == "linear"
    refute File.exists?(Path.join(Path.dirname(candidate), "relative-workspaces"))
  end

  test "reload refuses execution of a Project profile and keeps the previous workflow" do
    original = Config.settings!().tracker
    original_prompt = Config.workflow_prompt()

    log =
      capture_log(fn ->
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github_projects",
          prompt: "This inspection-only profile must never become executable."
        )

        assert {:error, :github_projects_execution_disabled} = WorkflowStore.force_reload()
        assert Config.settings!().tracker == original
        assert Config.workflow_prompt() == original_prompt
      end)

    assert log =~ "github_projects_execution_disabled"
    assert log =~ "keeping last known good configuration"
  end
end
