defmodule SymphonyElixir.DeliveryObserverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DeliveryGateSupport, as: Gate
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.{Client, Observation, Ownership, Runs, Settings}

  setup do
    cache = start_supervised!(F.Cache)
    f = F.fixture()
    %{f: f, cache: cache, opts: F.opts(f, cache)}
  end

  test "full observation observes an empty board but never grants execution", %{f: f, opts: opts} do
    {:ok, observation} = Delivery.observe(f.config, opts)
    assert observation.complete
    assert observation.facts["deployment"]["result"] == "success"
    assert observation.facts["deployment"]["environment_ready"]
    assert observation.reasons == ["manual_dev_validation_required"]
    refute observation.execution_enabled
    refute observation.next_task_allowed
    refute observation.facts["readiness_is_live"]
    assert Jason.encode!(observation) =~ "deployment_evidence"
    refute Jason.encode!(observation) =~ "fixture-token"
    {:ok, context} = Observation.context(nil)
    assert :ok = Observation.validate(observation, f.settings, context)
    assert {:error, :observer_context_required} = Observation.commands(observation, f.settings, context)
  end

  test "retains owner outside pilot filter and binds CI without consuming another reservation", %{f: f, cache: cache} do
    f = %{f | project: put_in(f.project, ["items"], [F.item()]), prs: [F.pr()], ci_runs: [F.ci_run()]}
    config = put_in(f.config.tracker.provider["item_ids"], ["other-item"]).config
    {:ok, selected_settings} = Settings.parse(config)
    context = context(Gate.reviewed())
    opts = Keyword.put(F.opts(f, cache), :context, context)
    {:ok, first} = Delivery.observe(config, opts)
    {:ok, second} = Delivery.observe(config, opts)
    assert first.complete
    assert first.facts["ci"]["result"] == "success"
    assert first.facts["ci"]["origin"] == "reserved"
    assert first.facts["ci"]["tested_sha"] == F.sha("c")
    assert first.facts["ci"]["head_sha"] == F.sha("b")
    assert {:ok, [%{action: "observe_ci", args: args}]} = Observation.commands(first, selected_settings, context)
    assert args["reservation_id"] == "ci-1"
    assert {:ok, [%{args: ^args}]} = Observation.commands(second, selected_settings, context)
    assert map_size(context.state["cycle"]["budget"]["ci"]) == 1
    assert first.facts["task"] == %{"item_id" => "item-A", "issue_id" => "issue-A"}
  end

  test "cancellation and recovery never become release commands", %{f: f, cache: cache} do
    primary = Gate.reviewed() |> Gate.apply!("request_cancel", Gate.operator())
    f = %{f | project: put_in(f.project, ["items"], [F.item()]), ci_runs: [F.ci_run()]}
    f = Map.put(f, :pr, Map.merge(F.pr(), %{"merged" => true, "state" => "closed", "merge_commit_sha" => F.sha()}))
    context = context(primary)
    {:ok, obs} = Delivery.observe(f.config, Keyword.put(F.opts(f, cache), :context, context))
    assert obs.complete
    assert "operator_cancel_pending" in obs.reasons
    assert obs.facts["cancellation_pending"]
    assert {:ok, commands} = Observation.commands(obs, f.settings, context)
    assert Enum.any?(commands, &(&1.action == "merged"))
    refute Enum.any?(commands, &(&1.action in ~w(complete finish_cancel assign_recovery validate_dev)))

    recovery = Gate.reviewed() |> Gate.apply!("block", %{"reason" => "needs_recovery"}) |> Gate.apply!("assign_recovery", Gate.recovery())
    {:ok, obs} = Delivery.observe(f.config, Keyword.put(F.opts(f, cache), :context, context(recovery)))
    assert obs.complete
    assert "primary_merged_during_recovery" in obs.reasons
    assert "recovery_owner_retained" in obs.reasons
    assert obs.facts["owner"] == recovery["cycle"]["owner"]
    assert obs.facts["task"] == recovery["cycle"]["task"]
  end

  test "stale epoch revision scope and changed restored state reject late observations", %{f: f, opts: opts} do
    context = context(Gate.reviewed())
    observation = Observation.new(f.settings, context, %{}, [])

    for changed <- [put_in(context, [:version, :revision], 9), put_in(context, [:version, :epoch], "restart"), %{context | state: Gate.reviewed() |> Gate.apply!("request_cancel", Gate.operator())}] do
      assert {:error, :stale_observation} = Observation.commands(observation, f.settings, changed)
    end

    changed_settings = put_in(f.settings, [:gate, :scope, "repo"], "other/app")
    assert {:error, :observation_scope_changed} = Observation.validate(observation, changed_settings, context)
    incomplete = %{observation | complete: false}
    assert {:error, :observation_incomplete} = Observation.validate(incomplete, f.settings, context)
    assert {:ok, []} = Observation.commands(observation, f.settings, context)
    assert {:error, :invalid_observer_context} = Delivery.observe(f.config, Keyword.put(opts, :context, %{context | mode: :recovery_required}))
    assert {:error, :invalid_observer_context} = Observation.context(%{})
  end

  test "changed dev on final read discards old success", %{f: f, opts: opts} do
    counter = :atomics.new(1, [])

    http = fn request ->
      if String.ends_with?(request[:url], "/git/ref/heads/dev") and :atomics.add_get(counter, 1, 1) > 1 do
        F.ok(%{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => F.sha("d")}})
      else
        F.response(f, request)
      end
    end

    {:ok, obs} = Delivery.observe(f.config, Keyword.put(opts, :http, http))
    refute obs.complete
    assert obs.reasons == ["observation_changed"]
    assert obs.facts == %{}
  end

  test "deadline bounds even a stalled Project reader, and exceptions cannot leak credentials", %{f: f, opts: opts} do
    slow = fn _, _ -> Process.sleep(:infinity) end
    {:ok, obs} = Delivery.observe(f.config, Keyword.merge(opts, deadline_ms: 25, project_reader: slow))
    refute obs.complete
    assert obs.reasons == ["observation_deadline"]

    for reader <- [fn _, _ -> raise "private-token" end, fn _, _ -> throw("private-token") end] do
      {:ok, obs} = Delivery.observe(f.config, Keyword.put(opts, :project_reader, reader))
      refute obs.complete
      refute Jason.encode!(obs) =~ "private-token"
    end
  end

  test "transport and invalid scope give bounded incomplete diagnostics", %{f: f, opts: opts} do
    for reply <- [{:error, :socket_down}, F.ok(%{}), F.ok(%{"id" => 2, "node_id" => "wrong", "full_name" => "other/app"})] do
      {:ok, obs} = Delivery.observe(f.config, Keyword.put(opts, :http, fn _ -> reply end))
      refute obs.complete
      refute obs.next_task_allowed
    end

    errors = [
      {:github_delivery_http, 404},
      {:github_delivery_limited, 120},
      # Nested unexpected details must be redacted.
      {:github_projects_http, 403, nil},
      {:unexpected, "secret"}
    ]

    for error <- errors do
      {:ok, ctx} = Observation.context(nil)
      obs = Observation.failure(f.settings, ctx, error)
      refute obs.complete
      refute Jason.encode!(obs) =~ "secret"
    end
  end

  test "unowned blockers include cards outside the pilot and retain archived ownership", %{f: f, cache: cache} do
    client = F.client(f, cache)
    {:ok, ctx} = Observation.context(nil)

    for row <- [F.item(), %{F.item() | "state" => nil}, put_in(F.item(), ["native_ref", "repo"], nil)] do
      project = %{"items" => [row]}
      {:ok, _, reasons} = Ownership.observe(client, ctx, project, [], F.repo(), F.sha())
      assert reasons != []
    end

    for row <- [%{F.item() | "state" => "Backlog"}, put_in(F.item(), ["native_ref", "repo"], "other/app")] do
      {:ok, _, []} = Ownership.observe(client, ctx, %{"items" => [row]}, [], F.repo(), F.sha())
    end

    for {row, reason} <- [
          {%{F.item() | "archived" => true}, "owner_item_archived"},
          {%{F.item() | "issue_state" => "CLOSED"}, "owner_issue_closed"},
          {%{F.item() | "state" => "Done"}, "owner_item_done_requires_reconciliation"},
          {F.item("item-A", "different"), "owner_issue_changed"}
        ] do
      {:ok, _, reasons} = Ownership.observe(client, context(Gate.initial()), %{"items" => [row]}, [], F.repo(), F.sha())
      assert reason in reasons
    end

    {:ok, _, reasons} = Ownership.observe(client, context(Gate.initial()), %{"items" => []}, [], F.repo(), F.sha())
    assert "owner_item_missing" in reasons
  end

  test "open draft closed and unbound PRs remain operator concerns", %{f: f, cache: cache} do
    scenarios = [{%{"draft" => true}, "pr_draft"}, {%{"state" => "closed"}, "pr_closed_without_merge"}, {%{"head" => put_in(F.pr()["head"], ["sha"], F.sha("d"))}, "pr_head_changed"}]
    project = %{"items" => [F.item()]}
    ctx = context(Gate.reviewed())

    for {changes, reason} <- scenarios do
      f = Map.put(f, :pr, Map.merge(F.pr(), changes))
      {:ok, _, reasons} = Ownership.observe(F.client(f, cache), ctx, project, [], F.repo(), F.sha())
      assert reason in reasons
    end

    ctx = context(Gate.initial())
    {:ok, facts, reasons} = Ownership.observe(F.client(f, cache), ctx, %{"items" => []}, [F.pr()], F.repo(), F.sha())
    assert facts["pr"] == nil
    assert "pr_association_requires_operator" in reasons
    invalid_inventory = [Map.put(F.pr(), "number", nil)]

    assert {:error, :open_pr_inventory_unconfirmed} =
             Ownership.observe(F.client(f, cache), ctx, project, invalid_inventory, F.repo(), F.sha())

    for pr <- [put_in(F.pr(), ["base", "ref"], "main"), put_in(F.pr(), ["head", "repo", "id"], 2), Map.put(F.pr(), "merged", nil)] do
      assert {:error, :pr_identity_unconfirmed} = Ownership.observe(F.client(Map.put(f, :pr, pr), cache), context(Gate.reviewed()), %{"items" => []}, [], F.repo(), F.sha())
    end
  end

  test "squash merge ancestry uses merge result and detects removed or replaced merge", %{f: f, cache: cache} do
    pr = Map.merge(F.pr(), %{"state" => "closed", "merged" => true})
    f = Map.put(f, :pr, pr)
    {:ok, facts, _} = Ownership.observe(F.client(f, cache), context(Gate.merged()), %{"items" => [F.item()]}, [], F.repo(), F.sha())
    assert facts["pr"]["ancestry"] == "included"
    client = F.client(f, cache)

    for {body, reason} <- [
          {%{"base_commit" => %{"sha" => F.sha("c")}, "status" => "diverged", "merge_base_commit" => %{"sha" => F.sha("d")}}, "merge_ancestry_missing"},
          {%{"base_commit" => %{"sha" => F.sha("d")}}, :merge_ancestry_unconfirmed}
        ] do
      http = fn opts -> if String.contains?(opts[:url], "/compare/"), do: F.ok(body), else: F.response(f, opts) end
      result = Ownership.observe(%{client | opts: Keyword.put(client.opts, :http, http)}, context(Gate.merged()), %{"items" => []}, [], F.repo(), F.sha())
      if is_atom(reason), do: assert(result == {:error, reason}), else: assert(reason in elem(result, 2))
    end

    f = Map.put(f, :pr, Map.put(pr, "merge_commit_sha", F.sha("e")))
    {:ok, _, reasons} = Ownership.observe(F.client(f, cache), context(Gate.merged()), %{"items" => []}, [], F.repo(), F.sha())
    assert "merge_ancestry_changed" in reasons
    f = Map.put(f, :pr, F.pr())
    {:ok, _, reasons} = Ownership.observe(F.client(f, cache), context(Gate.merged()), %{"items" => []}, [], F.repo(), F.sha())
    assert "merge_ancestry_changed" in reasons
  end

  test "old green never hides later pending failure or rerun of an older SHA", %{f: f, cache: cache} do
    for {changes, expected} <- [
          {%{"status" => "in_progress", "conclusion" => nil}, "pending"},
          {%{"conclusion" => "failure"}, "failure"},
          {%{"conclusion" => "cancelled"}, "failure"},
          {%{"conclusion" => "neutral"}, "unknown"},
          {%{"head_sha" => F.sha("b"), "run_attempt" => 2}, "unknown"}
        ] do
      later = Map.merge(f.run, Map.merge(%{"id" => 21, "run_started_at" => "2026-09-16T11:00:00Z", "updated_at" => "2026-09-16T11:01:00Z"}, changes))
      inventory = %{workflow: F.workflow(10, f.run["path"]), runs: [f.run, later]}
      assert {:ok, fact, _} = Runs.deployment(F.client(f, cache), inventory, f.policy, F.sha(), F.repo())
      assert fact["result"] == expected
      refute fact["environment_ready"]
    end

    overlap = Map.put(f.run, "id", 21)
    assert {:ok, _, ["deployment_attempts_overlap"]} = Runs.deployment(F.client(f, cache), %{runs: [f.run, overlap]}, f.policy, F.sha(), F.repo())
    assert {:ok, _, ["deployment_missing"]} = Runs.deployment(F.client(f, cache), %{runs: []}, f.policy, F.sha(), F.repo())
  end

  test "CI cancellation pending neutral external and invalid test merge are distinct", %{f: f, cache: cache} do
    ctx = context(Gate.reviewed())
    {:ok, facts, _} = Ownership.observe(F.client(f, cache), ctx, %{"items" => [F.item()]}, [], F.repo(), F.sha())

    for {changes, expected} <- [
          {%{"status" => "queued", "conclusion" => nil}, "pending"},
          {%{"conclusion" => "cancelled"}, "cancelled"},
          {%{"conclusion" => "failure"}, "failure"},
          {%{"conclusion" => "neutral"}, "unknown"}
        ] do
      run = Map.merge(F.ci_run(), changes)
      inventory = %{workflow: F.workflow(11, run["path"]), runs: [run]}
      assert {:ok, ci, _} = Runs.ci(F.client(f, cache), inventory, f.policy, facts["pr"], Gate.initial()["cycle"], F.sha())
      assert ci["result"] == expected
      assert ci["origin"] == "external"
    end

    for changes <- [%{"referenced_workflows" => []}, %{"head_sha" => F.sha("d")}, %{"pull_requests" => [], "referenced_workflows" => []}] do
      inventory = %{workflow: F.workflow(11, ".github/workflows/pr-ci.yml"), runs: [Map.merge(F.ci_run(), changes)]}
      result = Runs.ci(F.client(f, cache), inventory, f.policy, facts["pr"], Gate.reviewed()["cycle"], F.sha())
      refute match?({:ok, %{"result" => "success"}, _}, result)
    end
  end

  test "settings fail closed and fingerprints include the pinned observer policy", %{f: f} do
    assert {:ok, _} = Settings.parse(f.config)

    for values <- [%{}, %{"unexpected" => "x"}, %{"contract_commit" => "branch"}, %{"contract_sha256" => "bad"}, %{"deployment_workflow" => "../../other.yml"}, %{"environment" => ""}] do
      supplied = if values == %{}, do: %{}, else: Map.merge(f.config.delivery.observer, values)
      assert {:error, _} = Settings.parse(put_in(f.config.delivery.observer, supplied).config)
    end

    assert {:error, _} = Settings.parse(put_in(f.config.delivery.base_branch, "main").config)
    assert {:error, _} = Settings.parse(put_in(f.config.tracker.kind, "linear").config)
    assert {:error, _} = Settings.parse(put_in(f.config.delivery.state_path, "/worker/workspaces/store.json").config)
    refute Settings.sha?("A" <> String.duplicate("a", 39))
    refute Settings.id?(9_007_199_254_740_992)
  end

  defp context(state), do: %{version: %{epoch: "epoch-one", revision: 4}, mode: :needs_reconciliation, state: state}

  test "only the expected status update refreshes a running interval watch", %{f: f, cache: cache} do
    first = Map.put(F.item(), "state", "Ready for agent")
    f = %{f | project: put_in(f.project, ["items"], [first, F.item("item-B", "issue-B")])}
    ctx = context(Gate.initial())
    {:ok, observation} = Delivery.observe(f.config, Keyword.put(F.opts(f, cache), :context, ctx))
    row = hd(observation.facts["project"]["items"])
    changed = put_in(f, [:project, "items", Access.at(0), "state"], "Agent working")
    opts = F.opts(changed, cache)
    assert {:ok, %{"watch_digest" => digest}} = Delivery.watch_transition(f.config, ctx, observation.facts["watch_digest"], row, opts)
    refute digest == observation.facts["watch_digest"]
    assert {:error, :remote_conditions_changed} = Delivery.watch_transition(f.config, ctx, "wrong", row, opts)
    original_opts = F.opts(f, cache)
    assert {:error, :remote_conditions_changed} = Delivery.watch_transition(f.config, ctx, digest, row, original_opts)
  end

  test "first CI binds its reservation; missing earlier attempts remain external", %{f: f, cache: cache} do
    state = Gate.initial() |> Gate.apply!("reserve_ci", Gate.ci_request())
    facts = publication_pr(f, cache)
    run = F.ci_run()
    inventory = %{workflow: F.workflow(11, run["path"]), runs: [run]}
    assert {:ok, %{"origin" => "reserved"}, _} = Runs.ci(F.client(f, cache), inventory, f.policy, facts["pr"], state["cycle"], F.sha())
    duplicate = put_in(state, ["cycle", "budget", "ci", "duplicate"], state["cycle"]["budget"]["ci"]["ci-1"])
    assert {:error, :ambiguous_ci_reservation} = Runs.ci(F.client(f, cache), inventory, f.policy, facts["pr"], duplicate["cycle"], F.sha())
    inventory = %{inventory | runs: [Map.put(run, "run_attempt", 2)]}
    pending = put_in(inventory, [:runs, Access.at(0), "status"], "queued")
    assert {:ok, %{"origin" => "external"}, _} = Runs.ci(F.client(f, cache), pending, f.policy, facts["pr"], state["cycle"], F.sha())
  end

  test "failed verification steps are distinguished from unknown infrastructure failures", %{f: f, cache: cache} do
    facts = publication_pr(f, cache)
    run = Map.put(F.ci_run(), "conclusion", "failure")
    inventory = %{workflow: F.workflow(11, run["path"]), runs: [run]}
    policy = put_in(f.policy, [:pr_jobs, "verify", :steps, "check_test"], "Application tests")
    jobs = F.api_jobs(run, policy.pr_jobs)
    jobs = Enum.map(jobs, fn job -> update_in(job, ["steps"], fn steps -> Enum.map(steps, &if(&1["name"] == "Application tests", do: Map.put(&1, "conclusion", "failure"), else: &1)) end) end)

    opts =
      Keyword.put(F.opts(f, cache), :http, fn request ->
        if String.ends_with?(request[:url], "/jobs"), do: F.page("jobs", jobs, request), else: F.response(f, request)
      end)

    client = Client.new(f.settings, opts)
    assert {:ok, %{"failure_kind" => "verification"}, _} = Runs.ci(client, inventory, policy, facts["pr"], Gate.reviewed()["cycle"], F.sha())
  end

  defp publication_pr(f, cache) do
    ctx = context(Gate.reviewed())
    {:ok, facts, _} = Ownership.observe(F.client(f, cache), ctx, %{"items" => [F.item()]}, [], F.repo(), F.sha())
    facts
  end
end
