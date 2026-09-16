defmodule SymphonyElixir.DeliveryRuntimePolicyTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.DeliveryGate.{Snapshot, State}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.DeliveryRuntime.{HookContext, Policy}
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.Observation
  alias SymphonyElixir.Tracker.Issue

  test "admission distinguishes explicit recovery from ordinary broken dev and revoked cards" do
    f = F.fixture()
    state = G.initial()

    row = %{
      "item_id" => "item-A",
      "eligible" => true,
      "archived" => false,
      "issue_state" => "OPEN",
      "state" => "Ready for agent",
      "native_ref" => %{"issue_id" => "issue-A", "repo" => f.settings.repo}
    }

    issue = %Issue{id: "item-A", dispatchable: true, native_ref: row["native_ref"]}
    facts = %{"project" => %{"items" => [row]}, "dev_sha" => G.sha(), "deployment" => G.deployment("a")}
    obs = %Observation{facts: facts, reasons: ["manual_dev_validation_required"]}
    assert :ok = Policy.admission(f.settings, state, obs, issue)
    revoked = %{issue | dispatchable: false}
    assert {:error, :task_permission_required} = Policy.admission(f.settings, state, obs, revoked)
    assert {:error, :task_permission_required} = Policy.admission(f.settings, state, put_in(obs.facts["project"]["items"], [%{row | "eligible" => false}]), issue)
    failed = %{obs | reasons: ["deployment_failure"]}
    assert {:error, :remote_delivery_blocked} = Policy.admission(f.settings, state, failed, issue)
    assert {:error, :unvalidated_base} = Policy.admission(f.settings, state, put_in(obs.facts["dev_sha"], G.sha("c")), issue)
    assert {:error, :new_task_not_ready} = Policy.admission(f.settings, %{state | "cycle" => nil}, put_in(obs.facts["project"]["items"], [%{row | "state" => "Agent working"}]), issue)
    recovery = state |> G.apply!("block", %{"reason" => "broken"}) |> G.apply!("assign_recovery", G.recovery())
    row = %{row | "item_id" => "item-R", "native_ref" => %{"issue_id" => "issue-R", "repo" => f.settings.repo}}
    issue = %{issue | id: "item-R", native_ref: row["native_ref"]}
    obs = %{obs | facts: %{facts | "project" => %{"items" => [row]}, "dev_sha" => G.sha("c")}, reasons: ["deployment_failure", "recovery_owner_retained"]}
    assert :ok = Policy.admission(f.settings, recovery, obs, issue)
    assert {:error, :recovery_base_changed} = Policy.admission(f.settings, recovery, put_in(obs.facts["dev_sha"], G.sha()), issue)
    filtered = put_in(f.settings.project.item_ids, ["item-A"]).settings
    assert {:error, :task_permission_required} = Policy.admission(filtered, recovery, obs, issue)
  end

  test "review continuation retains the PR and counters and requires extra work budget" do
    reviewed = G.reviewed()
    args = Map.merge(G.operator(), %{"sha" => G.sha(), "head_sha" => G.sha("b"), "pr_number" => 7, "initial_ms" => 60_000, "fix_ms" => 0, "fixes" => 0, "ci_attempts" => 1, "retries_per_sha" => 0})
    assert {:ok, resumed} = State.apply_command(reviewed, "review_resume", args)
    assert resumed["cycle"]["phase"] == "reserved"
    assert resumed["cycle"]["work"] == reviewed["cycle"]["work"]
    assert resumed["cycle"]["budget"]["ci"] == reviewed["cycle"]["budget"]["ci"]
    assert resumed["cycle"]["budget"]["limits"]["initial_ms"] == 3_660_000

    for change <- [%{"initial_ms" => 0}, %{"pr_number" => 8}, %{"head_sha" => G.sha("c")}] do
      assert {:error, :review_resume_not_allowed} = State.apply_command(reviewed, "review_resume", Map.merge(args, change))
    end

    cancelled = G.apply!(reviewed, "request_cancel", G.operator())
    assert {:error, :review_resume_not_allowed} = State.apply_command(cancelled, "review_resume", args)
    snapshot = Snapshot.new(%{})

    commands = [
      {"bootstrap", G.validation()},
      {"reserve", G.task()},
      {"reserve_ci", G.ci_request()},
      {"observe_ci", G.ci_result()},
      {"handoff", %{"pr_number" => 7, "sha" => G.sha("b")}},
      {"review_resume", args}
    ]

    saved =
      Enum.reduce(commands, snapshot, fn {action, data}, snapshot ->
        {:ok, next, :new} = Snapshot.append(snapshot, action, snapshot["revision"], action, data, 1)
        next
      end)

    assert {:ok, ^saved} = Snapshot.decode(saved, %{})
  end

  test "hook data is bounded and shell metacharacters remain data" do
    f = F.fixture()
    context = HookContext.build(f.settings, %{version: %{epoch: "example", revision: 2}}, G.initial()["cycle"], "interval")
    assert context["mode"] == "new"
    context = Map.put(context, "issue_id", "Кавычки ' \" $HOME $(exit 19) `exit 23`\nстрока")
    assert {:ok, encoded} = HookContext.encode(context)
    assert Jason.decode!(encoded)["issue_id"] == context["issue_id"]
    assert {:ok, prefix} = HookContext.shell_prefix(context)
    {output, 0} = System.cmd("sh", ["-c", prefix <> "printf '%s' \"$SYMPHONY_DELIVERY_CONTEXT\""])
    assert Jason.decode!(output)["issue_id"] == context["issue_id"]
    assert {:error, :hook_context_invalid} = HookContext.encode(%{"large" => String.duplicate("x", 17_000)})
    recovery = %{G.initial()["cycle"] | "recovery" => %{}}
    assert HookContext.build(f.settings, %{version: %{}}, recovery, "i")["mode"] == "recovery"
  end

  test "cleanup requires completed owner identity and observations do not churn the journal" do
    closed = G.ready() |> G.apply!("complete", G.proof("c"))
    assert :ok = Policy.cleanup(%{mode: :reconciled, state: closed}, "/workspace/GHP-6974656d2d41")
    assert {:error, :workspace_ownership_unconfirmed} = Policy.cleanup(%{mode: :reconciled, state: closed}, "/workspace/another")
    assert {:error, :workspace_cycle_retained} = Policy.cleanup(%{mode: :needs_reconciliation, state: closed}, "/workspace/GHP-6974656d2d41")
    state = G.reviewed()
    refute Policy.new_command?(%{action: "observe_ci", args: G.ci_result()}, state)
    assert Policy.new_command?(%{action: "observe_ci", args: G.ci_result("ci-1", "failure")}, state)
    refute Policy.new_command?(%{action: "deployment", args: G.deployment()}, G.ready())
    assert Policy.new_command?(%{action: "merged"}, state)
  end

  test "watch checks remote pointer changes without accepting the report as new admission" do
    f = F.fixture()
    cache = start_supervised!(F.Cache)
    opts = F.opts(f, cache)
    {:ok, observation} = Delivery.observe(f.config, opts)
    {:ok, context} = Observation.context(nil)
    assert :ok = Delivery.watch(f.config, context, observation.facts["watch_digest"], opts)
    assert {:error, :remote_conditions_changed} = Delivery.watch(f.config, context, "changed", opts)
    assert {:error, :remote_conditions_changed} = Delivery.watch(nil, context, "changed", opts)
    limited = Keyword.put(opts, :http, fn _ -> {:ok, %{status: 429, headers: %{"retry-after" => ["120"]}, body: ""}} end)
    assert {:error, {:github_delivery_limited, 120}} = Delivery.watch(f.config, context, "changed", limited)
    assert {:error, :remote_conditions_unavailable} = Delivery.watch(f.config, context, "changed", Keyword.put(opts, :project_reader, fn _, _ -> raise "unavailable" end))
  end
end
