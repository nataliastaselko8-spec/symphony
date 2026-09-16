defmodule SymphonyElixir.DeliveryInspectionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Mix.Tasks.GithubProjects.Delivery.Inspect, as: InspectTask
  alias SymphonyElixir.{DeliveryGate, Workflow}
  alias SymphonyElixir.DeliveryGate.State
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.{Inspection, Observation}

  setup do
    root = Path.join(System.tmp_dir!(), "delivery-inspect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    f = F.fixture()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    key_path = Path.join(root, "fixture.pem")
    File.write!(key_path, :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)]))
    File.chmod!(key_path, 0o600)
    raw = put_in(f.raw, ["tracker", "provider", "github_app", "private_key_path"], key_path)
    path = Path.join(root, "WORKFLOW.md")
    File.write!(path, "---\n" <> Jason.encode!(raw) <> "\n---\nDo not execute this diagnostic workflow.\n")
    %{root: root, path: path, f: f, opts: Keyword.put(F.opts(f, nil), :credentials_cache_options, request_fun: &issue/4)}
  end

  test "one-shot diagnostic mints only read scope and does not start or mutate the runtime", c do
    before_runtime = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)
    assert {:ok, observation} = Inspection.run(c.path, c.opts)
    assert observation.complete
    assert Inspection.exit_code({:ok, observation}) == 0
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == before_runtime
    assert Process.whereis(SymphonyElixir.DeliveryGate) == nil
    refute File.exists?("/controller/delivery.json")
    {0, output} = Inspection.cli(["--workflow", c.path], c.opts)
    assert Jason.decode!(output)["manual_validation"] == "pending"
    refute output =~ "fixture-token"
    refute output =~ "fixture.pem"
    assert Inspection.exit_code({:ok, %{observation | reasons: ["operator_cancel_pending"]}}) == 2
    assert Inspection.exit_code({:ok, %{observation | complete: false}}) == 1
  end

  test "invalid files configuration and CLI flags have stable exit codes", c do
    assert {:error, :invalid_delivery_workflow} = Inspection.run(c.path <> ".missing")
    assert Inspection.exit_code({:error, :invalid_delivery_workflow}) == 1
    assert {0, help} = Inspection.cli(["--help"])
    assert help =~ "--workflow"

    for args <- [[], ["--bad"], ["--workflow", c.path, "extra"]] do
      assert {1, _} = Inspection.cli(args)
    end

    assert {1, output} = Inspection.cli(["--workflow", c.path <> ".missing"])
    assert Jason.decode!(output)["error"] == "invalid_delivery_workflow"
    {:ok, workflow} = Workflow.load(c.path)
    invalid = put_in(workflow.config, ["delivery", "observer"], nil)
    File.write!(c.path, "---\n" <> Jason.encode!(invalid) <> "\n---\n")
    assert {:error, :invalid_delivery_observer_settings} = Inspection.run(c.path)
    assert {:error, :invalid_delivery_observer_settings} = Delivery.observe(nil)
  end

  test "Mix command reports help and returns nonzero for invalid invocation" do
    assert capture_io(fn -> InspectTask.run(["--help"]) end) =~ "--workflow"
    capture_io(fn -> assert catch_exit(InspectTask.run([])) == {:shutdown, 1} end)
  end

  @tag skip: :os.type() != {:unix, :linux}
  test "real temporary controller retains budgets, cancellation and state across observations and restart", c do
    f = c.f |> F.on_dev("c") |> Map.put(:pr, Map.merge(F.pr(), %{"merged" => true, "state" => "closed"}))
    f = %{f | ci_runs: [F.ci_run()], project: put_in(f.project, ["items"], [F.item()])}
    settings = %{f.settings.gate | path: Path.join(c.root, "cycle.json")}
    {:ok, pid} = DeliveryGate.start_link(settings: settings)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    commands = [
      {"bootstrap", G.validation()},
      {"reserve", G.task()},
      {"reserve_ci", G.ci_request()},
      # CI is already reserved before its run is associated and the PR is handed off.
      {"observe_ci", G.ci_result()},
      {"handoff", %{"pr_number" => 7, "sha" => F.sha("b")}}
    ]

    for {action, args} <- commands do
      DeliveryGate.reconcile(pid, DeliveryGate.status(pid).version, settings.scope, args["sha"] || F.sha())
      assert {:ok, _} = DeliveryGate.execute(pid, DeliveryGate.status(pid).version, action, action, args)
    end

    cache = start_supervised!(F.Cache)
    context = DeliveryGate.status(pid)
    before = File.read!(settings.path)
    opts = Keyword.put(F.opts(f, cache), :context, context)
    assert {:ok, observation} = Delivery.observe(f.config, opts)
    assert observation.complete
    assert {:ok, [%{action: "merged", args: args}]} = Observation.commands(observation, f.settings, context)
    assert args == %{"pr_number" => 7, "sha" => F.sha("c")}
    assert File.read!(settings.path) == before
    assert {:ok, _} = DeliveryGate.execute(pid, context.version, "cancel", "request_cancel", G.operator())
    assert {:error, :stale_observation} = Observation.commands(observation, f.settings, DeliveryGate.status(pid))
    current = DeliveryGate.status(pid)
    :ok = DeliveryGate.reconcile(pid, current.version, settings.scope, F.sha("c"))
    assert {:ok, _} = DeliveryGate.execute(pid, current.version, "merge", "merged", args)
    current = DeliveryGate.status(pid)
    {:ok, observation} = Delivery.observe(f.config, Keyword.put(opts, :context, current))
    assert {:ok, [%{action: "deployment", args: deployment}]} = Observation.commands(observation, f.settings, current)
    :ok = DeliveryGate.reconcile(pid, current.version, settings.scope, F.sha("c"))
    assert {:ok, _} = DeliveryGate.execute(pid, current.version, "deploy", "deployment", deployment)
    after_delivery = DeliveryGate.status(pid)
    assert after_delivery.state["cycle"]["phase"] == "cancelling"
    assert after_delivery.state["cycle"]["validation"] == nil
    assert map_size(after_delivery.state["cycle"]["budget"]["ci"]) == 1
    GenServer.stop(pid)
    {:ok, restarted} = DeliveryGate.start_link(settings: settings)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    Process.unlink(restarted)
    assert {:error, :stale_observation} = Observation.validate(observation, f.settings, DeliveryGate.status(restarted))
    assert DeliveryGate.status(restarted).state["cycle"]["cancellation"] != nil
    refute DeliveryGate.status(restarted).state["status"] == "idle"
    empty = %{current | state: State.new()}
    assert {:ok, []} = Observation.commands(Observation.new(f.settings, empty, %{}, []), f.settings, empty)
  end

  defp issue("GET", "/app/installations/456", nil, _jwt) do
    {:ok, %{status: 200, body: %{"id" => 456, "app_id" => 123, "account" => %{"login" => "ExampleOrg", "type" => "Organization"}, "suspended_at" => nil}}}
  end

  defp issue("POST", "/app/installations/456/access_tokens", body, _jwt) do
    assert body["permissions"] == %{"actions" => "read", "pull_requests" => "read", "contents" => "read", "metadata" => "read"}
    assert body["repositories"] == ["app"]

    {:ok,
     %{
       status: 201,
       body: %{
         "token" => "fixture-token",
         "permissions" => body["permissions"],
         "expires_at" => DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.to_iso8601(),
         "repository_selection" => "selected",
         "repositories" => [%{"id" => 1, "full_name" => "ExampleOrg/app"}]
       }
     }}
  end
end
