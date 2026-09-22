defmodule SymphonyElixir.LifecycleRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGate.{Budget, Effects, Lifecycle, StatusSync}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.Observation
  alias SymphonyElixir.Operator.{Auth, Control, Credential, Decision}
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    f = F.fixture()
    roles = Map.merge(f.settings.project.states, %{"review" => "Human review", "dev_validation" => "Dev validation", "production_ready" => "Ready for production"})
    raw = f.raw |> put_in(["tracker", "provider", "states"], roles) |> put_in(["delivery", "state_path"], Path.join(root, "state.json"))
    {:ok, config} = Config.Schema.parse(raw)
    {:ok, settings} = Config.delivery_observer_settings(config)
    gate = start_supervised!({DeliveryGate, settings: settings.gate})
    tasks = start_supervised!(Task.Supervisor)
    cache = start_supervised!(F.Cache)

    initial = %{
      status: "Ready for agent",
      dev: G.sha(),
      deployment: G.deployment("a"),
      pr: nil,
      linked: false,
      writes: [],
      closed: false,
      allowed: true,
      comment_error: false,
      status_error: nil,
      requests: 0
    }

    remote = start_supervised!({Agent, fn -> initial end})

    observer = fn _, opts -> {:ok, Observation.new(settings, opts[:context], facts(Agent.get(remote, & &1), opts[:context]), ["manual_dev_validation_required"])} end
    options = [credentials_cache: cache, project_reader: fn _, _ -> {:ok, report(Agent.get(remote, & &1), roles)} end, observer: observer, http: &http(remote, roles, &1)]

    runtime_opts = [
      config: config,
      gate: gate,
      task_supervisor: tasks,
      observer: observer,
      status_options: options,
      stop_verifier: fn _ -> :stopped end,
      checkpoint_ms: 20,
      poll_ms: 0,
      watch: fn _, _, _, _ -> :ok end,
      watch_transition: fn _, _, _, _, _ -> {:ok, %{"row" => row(Agent.get(remote, & &1)), "watch_digest" => "digest"}} end,
      publication_step: &publish(remote, &1, &2, &3, &4, &5)
    ]

    token = Path.join(root, "login")
    :ok = Credential.create(token)
    auth = start_supervised!({Auth, settings: %{principal: "local:owner", credential_path: token, origin: "http://localhost"}})
    {:ok, session} = Auth.login(auth, String.trim(File.read!(token)))
    c = %{root: root, settings: settings, gate: gate, opts: runtime_opts, remote: remote, auth: auth, session: session}
    raw_event(c, "bootstrap", G.validation())
    c
  end

  defp row(r) do
    %{
      "item_id" => "item-A",
      "state" => r.status,
      "eligible" => r.allowed and r.status in ["Ready for agent", "Agent working"],
      "agent_allowed" => r.allowed,
      "in_scope" => true,
      "reasons" => if(r.status in ["Ready for agent", "Agent working"], do: [], else: ["inactive_status"]),
      "archived" => false,
      "issue_state" => if(r.closed, do: "CLOSED", else: "OPEN"),
      "native_ref" => %{"issue_id" => "issue-A", "repo" => "ExampleOrg/app", "agent_allowed_option_id" => if(r.allowed, do: "yes", else: "no")}
    }
  end

  defp report(r, roles),
    do: %{
      "project" => %{"id" => "project", "repo" => "ExampleOrg/app"},
      "items" => [row(r)],
      "schema" => %{"agent_allowed_option_id" => "yes", "status" => %{"id" => "status", "options" => Enum.map(roles, fn {id, name} -> %{"id" => id, "name" => name} end)}}
    }

  defp facts(r, context) do
    cycle = context.state["cycle"]
    latest = if cycle, do: Budget.latest_ci(cycle["budget"])
    ci = if latest && cycle["work"]["pr_number"], do: Map.merge(G.ci_result(latest["reservation_id"]), %{"origin" => "reserved", "sha" => G.sha("b"), "head_sha" => G.sha("b"), "base_sha" => G.sha()})

    %{
      "repo" => "ExampleOrg/app",
      "project" => %{"items" => [row(r)]},
      "dev_sha" => r.dev,
      "deployment" => r.deployment,
      "pr" => r.pr,
      "ci" => ci,
      "open_pr_numbers" => if(r.pr && r.pr["state"] == "open", do: [7], else: []),
      "watch_digest" => "digest"
    }
  end

  defp http(remote, roles, options) do
    r = Agent.get(remote, & &1)
    query = get_in(options, [:json, "query"]) || ""

    cond do
      String.ends_with?(options[:url], "/git/ref/heads/dev") ->
        F.ok(%{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => r.dev}})

      String.ends_with?(options[:url], "/pulls") ->
        F.ok([%{"id" => 7, "number" => 7, "node_id" => "pr"}])

      query =~ "SymphonyPublicationIssue" ->
        F.ok(%{
          "data" => %{
            "node" => %{
              "id" => "issue-A",
              "state" => "OPEN",
              "repository" => %{"nameWithOwner" => "ExampleOrg/app"},
              "comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
              "closedByPullRequestsReferences" => %{"nodes" => if(r.linked, do: [%{"id" => "pr"}], else: []), "pageInfo" => %{"hasNextPage" => false}}
            }
          }
        })

      query =~ "SymphonyStatus" ->
        Agent.update(remote, &%{&1 | requests: &1.requests + 1})
        write_status(remote, roles, options, r.status_error)

      true ->
        flunk("Unexpected network operation")
    end
  end

  defp write_status(_, _, _, error) when not is_nil(error), do: error

  defp write_status(remote, roles, options, nil) do
    target = roles[options[:json]["variables"]["input"]["value"]["singleSelectOptionId"]]
    Agent.update(remote, &%{&1 | status: target, writes: &1.writes ++ [target]})
    F.ok(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "item-A"}}}})
  end

  defp publish(remote, _, _, effect, authorize, _) do
    step = Effects.next(effect) || "finalize"

    result = publication_result(step, effect)

    with :ok <- if(step == "finalize", do: :ok, else: authorize.(step, result)) do
      if step == "pull", do: Agent.update(remote, &%{&1 | pr: %{"state" => "open", "number" => 7, "head_sha" => G.sha("b")}})
      if step == "link", do: Agent.update(remote, &%{&1 | linked: true})
      if step == "comment" and Agent.get(remote, & &1.comment_error), do: {:error, :publication_report_unknown}, else: {:ok, step, result}
    end
  end

  defp publication_result(step, _) do
    case step do
      "push" -> %{"sha" => G.sha("b"), "digest" => String.duplicate("d", 64), "base_sha" => G.sha()}
      "pull" -> %{"pr_number" => 7, "pr_id" => "pr", "sha" => G.sha("b")}
      "link" -> %{"pr_id" => "pr", "linked" => true}
      "comment" -> %{"comment_id" => "comment"}
      "finalize" -> %{"pr_number" => 7, "sha" => G.sha("b")}
    end
  end

  defp raw_event(c, action, args) do
    context = DeliveryGate.status(c.gate)
    DeliveryGate.reconcile(c.gate, context.version, c.settings.gate.scope, args["sha"] || G.sha())
    assert {:ok, _} = DeliveryGate.execute(c.gate, context.version, "raw-#{System.unique_integer([:positive])}", action, args)
  end

  defp boot(c), do: start_supervised!({DeliveryRuntime, c.opts})
  defp await(fun, n \\ 600)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(10)
            await(fun, n - 1)
          )
      )

  defp ready(runtime) do
    await(fn ->
      s = DeliveryRuntime.status(runtime)
      s.observation != nil and s.gate.version == s.observation.expected_version and :sys.get_state(runtime).read == nil
    end)
  end

  defp synced(c, target), do: await(fn -> Agent.get(c.remote, & &1.status) == target and not StatusSync.pending?(DeliveryGate.status(c.gate).state) end)

  defp start_worker(c, runtime, target \\ "Agent working") do
    pid = dispatch_worker(c, runtime)
    synced(c, target)
    pid
  end

  defp dispatch_worker(c, runtime) do
    ready(runtime)
    parent = self()
    r = Agent.get(c.remote, & &1)
    issue = %Issue{id: "item-A", identifier: "GHP-6974656d2d41", title: "Task", state: r.status, dispatchable: true, native_ref: row(r)["native_ref"]}

    assert {:ok, pid} =
             DeliveryRuntime.dispatch(runtime, issue, nil, fn handle ->
               send(parent, {:started, self()})
               loop(parent, handle)
             end)

    assert_receive {:started, ^pid}, 1000
    pid
  end

  defp loop(parent, handle) do
    receive do
      {:tool, name, args} ->
        send(parent, {:tool, DeliveryRuntime.tool(handle, name, args)})
        loop(parent, handle)

      :finish ->
        :ok
    end
  end

  defp tool(pid, name, args \\ %{}) do
    send(pid, {:tool, name, args})
    assert_receive {:tool, result}, 2000
    result
  end

  defp operator(c, runtime, action, payload) do
    ready(runtime)
    assert {:ok, form} = Control.prepare(c.auth, c.session, runtime, action)
    assert {:ok, result} = Control.execute(c.auth, c.session, form.id, payload)
    {form, result}
  end

  test "start is controller-owned, crash before project_block persists blocking, and resume needs no manual card move", c do
    raw_event(c, "reserve", G.task())
    runtime = boot(c)
    pid = start_worker(c, runtime)
    assert {:ok, %{"status" => "controller_managed"}} = tool(pid, "project_start")
    assert Agent.get(c.remote, & &1.writes) == ["Agent working"]
    Process.exit(pid, :kill)
    synced(c, "Needs human decision")
    operator(c, runtime, "resume", %{"reason" => "Fixed worker configuration"})
    synced(c, "Agent working")
    assert DeliveryGate.status(c.gate).state["cycle"]["work"]["branch"] == "agent/task-a"
    pid = start_worker(c, runtime)
    send(pid, :finish)
    synced(c, "Needs human decision")
    assert DeliveryGate.status(c.gate).state["cycle"]["block_reason"] == "worker_finished_without_handoff"
  end

  test "publication waits for CI and linkage, explicit review and rework preserve the PR", c do
    raw_event(c, "reserve", G.task())
    runtime = boot(c)
    pid = start_worker(c, runtime)
    assert {:ok, %{"operation_id" => id}} = tool(pid, "project_prepare_pr", %{"sha" => G.sha("b"), "title" => "Feature", "body" => "Verified changes"})
    assert {:ok, _} = tool(pid, "project_handoff", %{"operation_id" => id})
    synced(c, "PR ready")
    assert Agent.get(c.remote, & &1.linked)
    {form, _} = operator(c, runtime, "review_started", %{"reason" => "Reviewing the exact PR"})
    assert {:ok, %{replayed: true}} = Control.execute(c.auth, c.session, form.id, %{"reason" => "Reviewing the exact PR"})
    synced(c, "Human review")
    payload = %{"reason" => "Address review feedback", "initial_minutes" => "1", "fix_minutes" => "0", "fixes" => "0", "ci_attempts" => "0", "retries_per_sha" => "0"}
    operator(c, runtime, "review_resume", payload)
    synced(c, "Agent working")
    cycle = DeliveryGate.status(c.gate).state["cycle"]
    assert cycle["work"]["pr_number"] == 7 and cycle["work"]["branch"] == "agent/task-a"
    assert cycle["budget"]["ci_floor"] >= 1
  end

  test "block status is independent of a failed comment", c do
    raw_event(c, "reserve", G.task())
    runtime = boot(c)
    pid = start_worker(c, runtime)
    Agent.update(c.remote, &%{&1 | comment_error: true})
    assert {:ok, _} = tool(pid, "project_block", %{"body" => "Cannot create candidate commit"})
    synced(c, "Needs human decision")
    await(fn -> DeliveryGate.status(c.gate).state["cycle"]["block_reason"] == "publication_requires_decision" end)
    assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "needs_human_decision"
    assert Agent.get(c.remote, & &1.writes) == ["Agent working", "Needs human decision"]
  end

  test "closed merged issue moves through dev validation; failed validation holds until an explicit positive decision", c do
    commands = [{"reserve", G.task()}, {"reserve_ci", G.ci_request()}, {"observe_ci", G.ci_result()}, {"handoff", %{"pr_number" => 7, "sha" => G.sha("b")}}]
    for {action, args} <- commands, do: raw_event(c, action, args)

    Agent.update(
      c.remote,
      &%{
        &1
        | status: "PR ready",
          closed: true,
          dev: G.sha("c"),
          deployment: Map.put(G.deployment(), "result", "pending"),
          pr: %{"state" => "merged", "number" => 7, "head_sha" => G.sha("b"), "merge_sha" => G.sha("c"), "ancestry" => "included"}
      }
    )

    runtime = boot(c)
    synced(c, "Dev validation")
    Agent.update(c.remote, &%{&1 | deployment: G.deployment()})
    DeliveryRuntime.refresh(runtime)
    await(fn -> DeliveryGate.status(c.gate).state["cycle"]["phase"] == "awaiting_validation" end)
    synced(c, "Dev validation")
    operator(c, runtime, "validation_failed", %{"reason" => "Application scenario failed"})
    synced(c, "Needs human decision")
    Agent.update(c.remote, &%{&1 | deployment: G.deployment("c", 2)})
    DeliveryRuntime.refresh(runtime)
    await(fn -> get_in(DeliveryGate.status(c.gate).state, ["cycle", "deployment", "run_attempt"]) == 2 end)
    synced(c, "Needs human decision")
    assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "needs_human_decision"
    operator(c, runtime, "resume", %{"reason" => "New deployment inspected; ready for manual validation"})
    synced(c, "Dev validation")
    assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "awaiting_validation"
    operator(c, runtime, "validate", %{"reason" => "Application and services checked", "criteria" => Decision.criteria()})
    synced(c, "Ready for production")
    assert DeliveryGate.status(c.gate).state["cycle"] == nil
    assert DeliveryGate.status(c.gate).state["last_cycle"]["validation"]["run_attempt"] == 2
  end

  test "explicit recheck retries a rejected write after permission is repaired", c do
    raw_event(c, "reserve", G.task())
    Agent.update(c.remote, &%{&1 | status_error: {:ok, %{status: 403, headers: %{}}}})
    runtime = boot(c)
    ready(runtime)
    assert {:ok, _} = DeliveryRuntime.command(runtime, DeliveryGate.status(c.gate).version, "block", "block", %{"reason" => "Preparation failed"})
    await(fn -> Enum.any?(StatusSync.operations(DeliveryGate.status(c.gate).state), &(&1["status"] == "failed")) end)
    assert Agent.get(c.remote, & &1.requests) == 1
    Agent.update(c.remote, &%{&1 | status_error: nil})
    operator(c, runtime, "recheck_status", %{"reason" => "Restored Projects write permission"})
    synced(c, "Needs human decision")
    assert Agent.get(c.remote, & &1.requests) == 2
    assert DeliveryRuntime.status(runtime).worker == nil
  end

  test "explicit recheck of an unknown write reads only and never resets its send fence", c do
    raw_event(c, "reserve", G.task())
    Agent.update(c.remote, &%{&1 | status_error: {:error, :timeout}})
    runtime = boot(c)
    ready(runtime)
    assert {:ok, _} = DeliveryRuntime.command(runtime, DeliveryGate.status(c.gate).version, "block", "block", %{"reason" => "Preparation failed"})
    await(fn -> Enum.any?(StatusSync.operations(DeliveryGate.status(c.gate).state), &(&1["status"] == "unknown")) end)
    operator(c, runtime, "recheck_status", %{"reason" => "Check ambiguous response again"})

    await(fn ->
      [op] = StatusSync.operations(DeliveryGate.status(c.gate).state)
      op["status"] == "unknown" and op["checks"] > 0
    end)

    assert Agent.get(c.remote, & &1.requests) == 1
    assert hd(StatusSync.operations(DeliveryGate.status(c.gate).state))["sent"]
  end

  test "a changed watch after the start write stops the worker and records human decision", c do
    raw_event(c, "reserve", G.task())
    opts = Keyword.put(c.opts, :watch_transition, fn _, _, _, _, _ -> {:error, :remote_conditions_changed} end)
    runtime = boot(%{c | opts: opts})
    start_worker(c, runtime, "Needs human decision")
    await(fn -> DeliveryRuntime.status(runtime).worker == nil end)
    assert Agent.get(c.remote, & &1.writes) == ["Agent working", "Needs human decision"]
  end

  test "slow start synchronization keeps its journal version and holds publication tools", c do
    raw_event(c, "reserve", G.task())
    Agent.update(c.remote, &Map.put(&1, :hold_status, true))
    parent = self()
    options = c.opts[:status_options]

    reader = fn tracker, opts ->
      if Agent.get_and_update(c.remote, fn r -> {r.hold_status, %{r | hold_status: false}} end) do
        send(parent, {:status_read, self()})
        receive do: (:continue -> :ok)
      end

      options[:project_reader].(tracker, opts)
    end

    runtime = boot(%{c | opts: Keyword.put(c.opts, :status_options, Keyword.put(options, :project_reader, reader))})
    pid = dispatch_worker(c, runtime)
    assert_receive {:status_read, task}, 1000
    version = DeliveryGate.status(c.gate).version
    send(runtime, :tick)
    assert DeliveryRuntime.status(runtime).worker.status == :running
    assert DeliveryGate.status(c.gate).version == version
    assert {:error, :status_sync_pending} = tool(pid, "project_prepare_pr", %{"sha" => G.sha("b"), "title" => "Wait", "body" => "Wait for status"})
    assert Agent.get(c.remote, & &1.writes) == []
    send(task, :continue)
    synced(c, "Agent working")
    assert DeliveryRuntime.status(runtime).worker.status == :running
    assert Agent.get(c.remote, & &1.writes) == ["Agent working"]
  end

  for sent <- [false, true] do
    @sent sent
    test "restart reconciles an older start intent during operator pause (sent=#{sent})", c do
      raw_event(c, "reserve", G.task())
      {action, args} = Lifecycle.wrap(c.settings, DeliveryGate.status(c.gate).state, "start_work", %{"interval_id" => "w", "budget" => "initial"}, "Ready for agent")
      raw_event(c, action, args)

      if @sent do
        [op] = StatusSync.operations(DeliveryGate.status(c.gate).state)
        raw_event(c, "status_result", %{"operation_id" => op["id"], "outcome" => "sent", "observed" => "Ready for agent", "error" => nil, "at_ms" => 1, "retry_at_ms" => 0})
        Agent.update(c.remote, &%{&1 | status: "Agent working", allowed: false})
      end

      raw_event(c, "stop_work", %{"interval_id" => "w", "elapsed_ms" => 10})
      pause = %{"kind" => "pause", "actor" => "local:owner", "reason" => "Pause while reconciling", "data" => %{}, "request_hash" => String.duplicate("a", 64)}
      {action, args} = Lifecycle.wrap(c.settings, DeliveryGate.status(c.gate).state, "operator_decision", pause, Agent.get(c.remote, & &1.status))
      raw_event(c, action, args)
      runtime = boot(c)
      synced(c, "Needs human decision")
      assert hd(StatusSync.operations(DeliveryGate.status(c.gate).state))["status"] == if(@sent, do: "confirmed", else: "superseded")
      assert Agent.get(c.remote, & &1.writes) == ["Needs human decision"]
      operator(c, runtime, "unpause", %{"reason" => "Reconciled; keep work blocked until explicit resume"})
      refute Decision.held?(DeliveryGate.status(c.gate).state)
      assert DeliveryGate.status(c.gate).state["cycle"]["phase"] == "needs_human_decision"
      assert DeliveryRuntime.status(runtime).worker == nil
    end
  end
end
