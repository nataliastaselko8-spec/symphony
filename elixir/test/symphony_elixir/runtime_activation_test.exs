defmodule SymphonyElixir.RuntimeActivationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentRuntimeSupervisor
  alias SymphonyElixir.Runtime.Activation

  setup do
    previous = Application.get_env(:symphony_elixir, :runtime_activation)
    names = ~w(SYMPHONY_RUNTIME_HELPER SYMPHONY_RUNTIME_CONFIG)
    environment = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :runtime_activation, previous)
      Enum.each(environment, fn {key, value} -> if value, do: System.put_env(key, value), else: System.delete_env(key) end)
    end)

    root = Path.dirname(Workflow.workflow_file_path())
    path = Path.join(root, "activation.md")
    helper = Path.join(root, "activation.py")
    response = Path.join(root, "response.json")
    raw = SymphonyElixir.DeliveryObserverSupport.raw_config()
    File.write!(path, "---\n" <> Jason.encode!(raw) <> "\n---\nFixture\n")
    {:ok, config} = Config.Schema.parse(raw)
    proof = %{"workflow" => path, "workflow_sha256" => :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower), "repo" => "ExampleOrg/app"}
    File.write!(response, Jason.encode!(%{"ok" => proof}))

    File.write!(
      helper,
      "import sys,json,struct\nn=struct.unpack('!I',sys.stdin.buffer.read(4))[0]\nsys.stdin.buffer.read(n)\nx=open(sys.argv[2],'rb').read()\nsys.stdout.buffer.write(struct.pack('!I',len(x))+x)\n"
    )

    System.put_env("SYMPHONY_RUNTIME_HELPER", helper)
    System.put_env("SYMPHONY_RUNTIME_CONFIG", response)
    %{path: path, config: config, response: response}
  end

  test "validated workflow binds settings, reload hash and repo", c do
    assert :ok = Activation.validate_workflow(c.path)
    assert :ok = Activation.validate_settings(c.config)
    assert Activation.current().settings == c.config
    File.write!(c.path, File.read!(c.path) <> "Changed\n")
    assert {:error, :github_projects_execution_disabled} = Activation.validate_settings(c.config)
    assert Activation.current() == nil
    assert {:error, :github_projects_execution_disabled} = Activation.validate_workflow(c.path)
  end

  test "missing proof rejects direct supervisor start and never keeps a previous activation", c do
    assert :ok = Activation.validate_workflow(c.path)
    File.write!(c.response, ~s({"error":"launcher_not_alive"}))
    assert {:error, :github_projects_execution_disabled} = Activation.validate_workflow(c.path)
    result = AgentRuntimeSupervisor.start_link(config: c.config, name: __MODULE__.Rejected)
    assert {:error, :github_projects_execution_disabled} = result
    assert Process.whereis(__MODULE__.Rejected) == nil
    assert {:error, :github_projects_execution_disabled} = Activation.validate_settings(c.config)
  end
end
