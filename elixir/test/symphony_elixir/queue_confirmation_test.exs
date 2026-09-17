defmodule SymphonyElixir.QueueConfirmationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.DeliveryGate.State
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery
  alias SymphonyElixir.GitHubProjects.Delivery.{Observation, QueueConfirmation}
  alias SymphonyElixir.Operator.{Decision, Policy, View}

  setup do
    f = F.fixture()
    queue = %{"state" => "paused", "reason" => "inherited_pause"}

    report =
      f.report
      |> put_in(["jobs", "queue_pause", "facts", "initial_state"], "paused")
      |> put_in(["jobs", "queue_pause", "facts", "resume_required"], "false")
      |> put_in(["jobs", "queue_finalize", "facts"], queue)
      |> put_in(["environment", "queue"], queue)
      |> put_in(["environment", "status"], "blocked")
      |> put_in(["environment", "blockers"], ["resume_queue_before_dev_validation"])

    f = F.repack(f, report)
    cache = start_supervised!(F.Cache)
    opts = F.opts(f, cache)
    {:ok, obs} = Delivery.observe(f.config, opts)
    now = System.system_time(:millisecond)
    form = %{id: "queue-form", action: "confirm_queue", actor: "local:owner"}
    payload = %{"reason" => "Checked development resources", "criteria" => QueueConfirmation.criteria(), "queue_resource" => "dev-delivery", "scheduler_resource" => "dev-scheduler"}
    obs = %{obs | facts: Map.put(obs.facts, "controller_now_ms", now)}
    {:ok, args} = Policy.build(form, payload, obs, f.settings, State.new())
    {:ok, state} = Decision.apply(State.new(), args)
    %{f: f, opts: opts, obs: obs, state: state, args: args, now: now, form: form, payload: payload}
  end

  test "real verified archive accepts supplemental testimony without rewriting it or validating dev", c do
    assert QueueConfirmation.candidate?(c.obs)
    context = %{version: %{epoch: "queue-test", revision: 1}, mode: :reconciled, state: c.state}
    {:ok, observed} = Delivery.observe(c.f.config, Keyword.put(c.opts, :context, context))
    assert observed.complete
    assert Policy.healthy?(observed)
    assert observed.facts["deployment"]["queue"]["state"] == "paused"
    assert observed.facts["deployment"]["blockers"] == ["resume_queue_before_dev_validation"]
    assert observed.facts["manual_queue_confirmation"]["source"] == "operator_manual"
    assert observed.reasons == ["manual_dev_validation_required"]
    refute observed.next_task_allowed
    assert c.state["baseline"] == nil
    assert c.f.report["environment"]["status"] == "blocked"
    assert QueueConfirmation.apply(observed, c.state, c.now) == observed

    status = %{
      gate: %{state: G.merged()},
      observation: c.obs,
      observation_age_ms: 0,
      reason: "environment_not_ready",
      worker: nil,
      restart_required: false
    }

    assert View.project(status).reason =~ "подтвердите состояние Queue"
    assert View.project(%{status | observation: %{c.obs | reasons: []}}).reason =~ "Среда ещё не готова"
  end

  test "missing observation disables confirmation even when prior Queue testimony is saved", c do
    status = %{
      gate: %{state: c.state},
      observation: nil,
      observation_age_ms: nil,
      reason: :observation_required,
      worker: nil,
      restart_required: false
    }

    panel = View.project(status)
    confirmation = Enum.find(panel.actions, &(&1.id == "confirm_queue"))
    refute confirmation.enabled
    assert panel.queue_confirmation == %{}
    assert panel.deployment == %{}
    assert {:error, :observation_required} = Policy.build(c.form, c.payload, nil, c.f.settings, c.state)
    assert QueueConfirmation.apply(nil, c.state, c.now) == nil
  end

  test "expiry, backwards clock, new attempt, digest and policy reject testimony; only accepted validation survives age", c do
    for now <- [c.now - 1, c.now + 1_800_000] do
      effective = QueueConfirmation.apply(c.obs, c.state, now)
      refute Policy.healthy?(effective)
      assert effective.facts["queue_confirmation_invalidated"]
    end

    context = %{version: %{epoch: "epoch", revision: 1}, mode: :reconciled, state: c.state}
    expired = Observation.new(c.f.settings, context, c.obs.facts, c.obs.reasons) |> QueueConfirmation.apply(c.state, c.now + 1_800_000)
    assert {:ok, [%{action: "invalidate_queue_confirmation", args: %{}}]} = Observation.commands(expired, c.f.settings, context)

    for facts <- [
          put_in(c.obs.facts, ["deployment", "run_attempt"], 2),
          put_in(c.obs.facts, ["deployment", "artifact_id"], 8),
          put_in(c.obs.facts, ["deployment", "digest"], "sha256:" <> String.duplicate("b", 64)),
          Map.put(c.obs.facts, "policy_hashes", %{"workflow" => String.duplicate("c", 64)})
        ] do
      refute Policy.healthy?(QueueConfirmation.apply(%{c.obs | facts: facts}, c.state, c.now))
    end

    assert Policy.healthy?(QueueConfirmation.apply(c.obs, c.state, c.now + 1_799_999))
    validation = %{"kind" => "validate", "actor" => "local:owner", "reason" => "App tested", "request_hash" => Policy.hash("test"), "data" => Map.put(G.proof(), "criteria", Decision.criteria())}
    {:ok, accepted} = Decision.apply(c.state, validation)
    assert accepted["queue_confirmation"]["validated"]
    assert Policy.healthy?(QueueConfirmation.apply(c.obs, accepted, c.now + 3_600_000))
    restored = G.apply!(accepted, "record_restore", G.operator())
    assert restored["queue_confirmation"] == nil
    refute Policy.healthy?(QueueConfirmation.apply(c.obs, restored, c.now))
  end

  test "merged cancellation and recovery complete only after both confirmations; problem and backup revoke evidence", c do
    args = put_in(c.args, ["data", "sha"], G.sha("c"))

    for initial <- [G.merged(), G.merged() |> G.apply!("request_cancel", G.operator())] do
      initial = G.apply!(initial, "deployment", Map.put(G.deployment(), "environment_ready", false))
      {:ok, confirmed} = Decision.apply(initial, args)
      assert confirmed["cycle"]["owner"] == initial["cycle"]["owner"]
      assert confirmed["baseline"] == nil
      ready = G.apply!(confirmed, "deployment", G.deployment())
      validation = %{args | "kind" => "validate", "data" => Map.put(G.proof("c"), "criteria", Decision.criteria())}
      assert {:ok, completed} = Decision.apply(ready, validation)
      assert completed["cycle"] == nil
      assert completed["queue_confirmation"]["validated"]
      assert {:ok, reported} = Decision.apply(completed, %{args | "kind" => "problem", "data" => %{}})
      assert reported["queue_confirmation"] == nil
      refute reported["baseline"]
      restored = G.apply!(confirmed, "record_restore", G.operator())
      assert restored["queue_confirmation"] == nil
      assert restored["cycle"]["owner"] == initial["cycle"]["owner"]
    end

    recovery =
      G.reviewed()
      |> G.apply!("block", %{"reason" => "broken dev"})
      |> G.apply!("assign_recovery", G.recovery())
      |> G.apply!("reserve_ci", G.ci_request("fix-ci"))
      |> G.apply!("observe_ci", G.ci_result("fix-ci"))
      |> G.apply!("handoff", %{"pr_number" => 8, "sha" => G.sha("b")})
      |> G.apply!("merged", %{"pr_number" => 8, "sha" => G.sha("c")})

    {:ok, confirmed} = Decision.apply(recovery, args)
    ready = G.apply!(confirmed, "deployment", G.deployment())
    {:ok, restored} = Decision.apply(ready, %{args | "kind" => "validate", "data" => Map.put(G.proof("c"), "criteria", Decision.criteria())})
    assert restored["cycle"]["owner"]["item_id"] == "item-A"
    assert restored["cycle"]["recovery"] == nil
    assert restored["queue_confirmation"]["validated"]
  end

  test "manual check cannot override protective pause, failed finalizers, unknown or incomplete evidence", c do
    for facts <- [
          put_in(c.obs.facts, ["deployment", "queue", "reason"], "protective_pause"),
          put_in(c.obs.facts, ["deployment", "complete"], false),
          put_in(c.obs.facts, ["deployment", "result"], "failure"),
          put_in(c.obs.facts, ["deployment", "scheduler"], "unknown"),
          put_in(c.obs.facts, ["deployment", "blockers"], ["resume_queue_before_dev_validation", "finalizer_failed"]),
          Map.put(c.obs.facts, "dev_sha", G.sha("b"))
        ] do
      observation = %{c.obs | facts: facts}
      refute QueueConfirmation.candidate?(observation)
      refute Policy.healthy?(QueueConfirmation.apply(observation, c.state, c.now))
      assert {:error, :environment_not_ready} = Policy.build(c.form, c.payload, observation, c.f.settings, c.state)
    end

    refute QueueConfirmation.candidate?(%{c.obs | complete: false})
    assert {:error, :remote_delivery_blocked} = Policy.build(c.form, c.payload, %{c.obs | reasons: ["unexpected_pr"]}, c.f.settings, c.state)

    bad_http = fn request ->
      if String.contains?(request[:url], "/artifacts"), do: F.ok(%{"total_count" => 0, "artifacts" => []}), else: F.response(c.f, request)
    end

    context = %{version: %{epoch: "queue-test", revision: 1}, mode: :reconciled, state: c.state}
    {:ok, incomplete} = Delivery.observe(c.f.config, Keyword.merge(c.opts, context: context, http: bad_http))
    refute incomplete.complete
    refute Policy.healthy?(incomplete)
  end

  test "fields and server time are mandatory, browser cannot supply actor or timestamps", c do
    for data <- [
          Map.delete(c.args["data"], "digest"),
          Map.put(c.args["data"], "criteria", []),
          Map.put(c.args["data"], "confirmed_at_ms", 0),
          Map.put(c.args["data"], "queue_resource", " "),
          Map.put(c.args["data"], "policy_hashes", %{"workflow" => "bad"})
        ] do
      assert {:error, :invalid_operator_decision} = Decision.validate(Map.put(c.args, "data", data))
    end

    assert {:error, :invalid_operator_payload} = Policy.build(c.form, Map.put(c.payload, "confirmed_at_ms", c.now), c.obs, c.f.settings, c.state)
    assert {:error, :invalid_operator_decision} = Policy.build(c.form, Map.put(c.payload, "criteria", []), c.obs, c.f.settings, c.state)
    active = G.initial() |> G.apply!("start_work", %{"interval_id" => "busy", "budget" => "initial"})
    assert {:error, :work_unresolved} = Decision.apply(active, c.args)
    assert {:error, :work_unresolved} = Decision.apply(active, %{c.args | "kind" => "validate", "data" => Map.put(G.proof(), "criteria", Decision.criteria())})
    assert {:ok, expired} = State.apply_command(c.state, "invalidate_queue_confirmation", %{})
    assert expired["queue_confirmation"] == nil
  end
end
