defmodule SymphonyElixir.OperatorTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.DeliveryGate.State
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.Operator.{Auth, Credential, Decision, Policy, View}

  setup do
    root = Path.join(System.tmp_dir!(), "operator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "credential")
    :ok = Credential.create(path)
    clock = start_supervised!({Agent, fn -> 0 end})
    settings = %{principal: "local:owner", credential_path: path, origin: "http://127.0.0.1:4080"}
    auth = start_supervised!({Auth, settings: settings, now: fn -> Agent.get(clock, & &1) end})
    {:ok, session} = Auth.login(auth, File.read!(path) |> String.trim())
    %{root: root, path: path, auth: auth, session: session, clock: clock, settings: settings}
  end

  test "credential is private, non-overwriting, and rejects unsafe files", c do
    assert {:ok, hash} = Credential.read(c.path)
    assert byte_size(hash) == 32
    assert {:error, :credential_creation_failed} = Credential.create(c.path)
    assert {:error, _} = Credential.read("relative")
    assert {:error, _} = Credential.create("relative")
    assert {:error, _} = Credential.read("/mnt/c/secret")
    assert {:error, _} = Credential.read(c.path <> <<0>>)
    assert {:error, _} = Credential.read(Path.join(c.root, "missing"))
    File.chmod!(c.path, 0o644)
    assert {:error, _} = Credential.read(c.path)
    File.chmod!(c.path, 0o600)
    File.write!(c.path, String.duplicate("!", 43))
    assert {:error, _} = Credential.read(c.path)
    File.write!(c.path, "short")
    assert {:error, _} = Credential.read(c.path)
    File.ln_s!(c.path, Path.join(c.root, "link"))
    assert {:error, _} = Credential.read(Path.join(c.root, "link"))
    File.mkdir_p!(Path.join(c.root, "private"))
    File.chmod!(Path.join(c.root, "private"), 0o700)
    File.ln_s!(c.root, Path.join(c.root, "parent-link"))
    assert {:error, _} = Credential.read(Path.join(c.root, "parent-link/private/token"))
    File.write!(Path.join(c.root, ".git"), "gitdir: elsewhere")
    assert {:error, _} = Credential.create(Path.join(c.root, "checkout-token"))
    File.chmod!(c.root, 0o755)
    assert {:error, _} = Credential.read(c.path)
  end

  test "settings constrain host, principal and port; disabled auth cannot log in", c do
    assert {:ok, nil} = Auth.settings(%{operator: %{}})
    params = %{host: "127.0.0.1", port: 4080, operator: %{"principal" => "local:owner", "credential_path" => c.path}}
    assert {:ok, %{origin: "http://127.0.0.1:4080"}} = Auth.settings(params)
    assert {:ok, %{origin: "http://[::1]:4080"}} = Auth.settings(%{params | host: "::1"})
    config = %{F.fixture().config | server: params}
    assert {:ok, _} = Auth.from_config(config)
    assert {:error, :operator_credential_inside_workspace} = Auth.from_config(put_in(config.workspace.root, c.root))
    assert {:ok, nil} = Auth.from_config(put_in(config.server.operator, %{}))

    for invalid <- [%{params | host: "0.0.0.0"}, %{params | port: 0}, put_in(params.operator["principal"], "github:bot"), %{params | operator: %{}} |> Map.delete(:operator)] do
      assert {:error, :invalid_operator_settings} = Auth.settings(invalid)
    end

    disabled = start_supervised!({Auth, settings: nil}, id: :disabled)
    assert {:ok, nil} = Auth.info(disabled)
    assert {:error, :operator_disabled} = Auth.login(disabled, "x")
    assert {:error, :operator_auth_unavailable} = Auth.info(:missing_auth)
    assert {:stop, :invalid_operator_credential} = Auth.init(settings: %{c.settings | credential_path: "missing"})
    assert %{state: :operator_credentials_redacted} = Auth.format_status(%{})
  end

  test "sessions expire, revoke sockets and bind bounded forms to one session", c do
    assert {:ok, "local:owner"} = Auth.check(c.auth, c.session, true)
    {:ok, other} = Auth.login(c.auth, File.read!(c.path) |> String.trim())
    {:ok, form} = Auth.prepare(c.auth, c.session, %{action: "pause"})
    assert form.actor == "local:owner"
    assert {:error, :operator_form_expired} = Auth.form(c.auth, other, form.id)
    assert {:ok, ^form} = Auth.form(c.auth, c.session, form.id)
    for _ <- 1..19, do: assert({:ok, _} = Auth.prepare(c.auth, c.session, %{}))
    assert {:error, :operator_form_unavailable} = Auth.prepare(c.auth, c.session, %{})
    assert {:error, :operator_form_unavailable} = Auth.prepare(c.auth, "missing", %{})
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "operator:" <> c.session)
    Agent.update(c.clock, fn _ -> 1_800_000 end)
    assert {:error, :operator_login_required} = Auth.check(c.auth, c.session)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:error, :operator_form_expired} = Auth.form(c.auth, c.session, form.id)
    {:ok, fresh} = Auth.login(c.auth, File.read!(c.path) |> String.trim())
    assert :ok = Auth.logout(c.auth, fresh)
    assert :ok = Auth.logout(c.auth, nil)
    assert :ok = Auth.revoke(c.auth)
    assert {:error, :operator_login_required} = Auth.check(c.auth, fresh)
  end

  test "login attempts and concurrent sessions are bounded", c do
    for _ <- 1..10, do: assert(:ok = Auth.allow_read(c.auth, c.session))
    assert {:error, :operator_read_rate_limited} = Auth.allow_read(c.auth, c.session)
    assert {:error, :operator_login_required} = Auth.allow_read(c.auth, "missing")
    assert is_binary(View.message(:operator_read_rate_limited))
    for value <- [nil, %{}, String.duplicate("x", 129), "wrong", "wrong"], do: assert({:error, :invalid_login} = Auth.login(c.auth, value))
    assert {:error, :login_rate_limited} = Auth.login(c.auth, "wrong")
    Agent.update(c.clock, fn _ -> 60_000 end)
    assert :ok = Auth.allow_read(c.auth, c.session)
    for _ <- 1..7, do: assert({:ok, _} = Auth.login(c.auth, File.read!(c.path) |> String.trim()))
    assert {:error, :session_limit} = Auth.login(c.auth, File.read!(c.path) |> String.trim())
    Agent.update(c.clock, fn _ -> 28_800_000 end)
    assert {:error, :operator_login_required} = Auth.check(c.auth, c.session)
  end

  defp decision(kind, data \\ %{}), do: %{"kind" => kind, "actor" => "local:owner", "reason" => "Checked by operator", "request_hash" => Policy.hash(kind), "data" => data}

  test "durable pause and negative validation retain ownership and fail closed without a cycle" do
    state = State.new()
    assert {:ok, paused} = State.apply_command(state, "operator_decision", decision("pause"))
    assert Decision.held?(paused)
    assert {:error, :operator_paused} = State.admission(paused, "new")
    assert {:ok, unpaused} = State.apply_command(paused, "operator_decision", decision("unpause"))
    refute Decision.held?(unpaused)
    assert {:ok, problem} = Decision.apply(state, decision("problem"))
    assert {:error, :environment_problem} = State.admission(problem, "new")
    assert {:ok, occupied} = Decision.apply(G.initial(), decision("problem"))
    assert occupied["cycle"]["owner"] == G.initial()["cycle"]["owner"]
    assert {:error, :environment_problem} = State.admission(occupied, "item-A")
    assert {:ok, recovered} = Decision.apply(occupied, decision("recovery", Map.drop(G.recovery(), ~w(actor reason))))
    refute Decision.held?(recovered)
    assert {:ok, cancelled} = Decision.apply(G.initial(), decision("cancel"))
    assert cancelled["cycle"]["cancellation"]["actor"] == "local:owner"
  end

  test "manual validation and completion are one transition; restores invalidate baseline" do
    proof = Map.put(G.proof(), "criteria", Decision.criteria())
    assert {:ok, boot} = State.apply_command(State.new(), "operator_decision", decision("validate", proof))
    assert boot["baseline"]["sha"] == G.sha()
    blocked = G.initial() |> G.apply!("block", %{"reason" => "operator_reported_problem"})
    assert {:ok, refreshed} = Decision.apply(blocked, decision("validate", proof))
    assert refreshed["cycle"]["id"] == "cycle-A"
    assert {:error, :baseline_validation_not_allowed} = Decision.apply(G.initial(), decision("validate", proof))
    working = G.initial() |> G.apply!("start_work", %{"interval_id" => "i", "budget" => "initial"})
    assert {:error, :work_unresolved} = Decision.apply(working, decision("validate", proof))
    ready = G.merged() |> G.apply!("deployment", G.deployment())
    validation = Map.put(G.proof("c"), "criteria", Decision.criteria())
    assert {:ok, done} = Decision.apply(ready, decision("validate", validation))
    assert done["cycle"] == nil and done["status"] == "idle"
    cancel = ready |> G.apply!("request_cancel", G.operator())
    assert {:ok, cancelled} = Decision.apply(cancel, decision("validate", validation))
    assert cancelled["cycle"] == nil
    assert {:ok, restored} = State.apply_command(done, "record_restore", G.operator())
    assert restored["baseline"] == nil
    assert {:ok, restored} = State.apply_command(working, "record_restore", G.operator())
    assert restored["baseline"] == nil
    assert {:error, :validation_not_current} = Decision.apply(ready, decision("validate", proof))
  end

  test "closed decision schema never delegates arbitrary commands" do
    for invalid <- [
          %{},
          decision("merge"),
          Map.put(decision("pause"), "extra", true),
          Map.put(decision("pause"), "request_hash", "bad"),
          decision("pause", %{"x" => 1}),
          decision("validate", G.proof())
        ] do
      assert {:error, :invalid_operator_decision} = Decision.validate(invalid)
    end

    assert :ok = Decision.validate(decision("cancel"))
    assert :ok = Decision.validate(decision("extend_budget", %{"initial_ms" => 60_000, "fix_ms" => 0, "fixes" => 0, "ci_attempts" => 0, "retries_per_sha" => 0}))
    assert {:error, :no_active_cycle} = Decision.apply(State.new(), decision("resume", %{"sha" => G.sha()}))
  end

  defp setup_policy(state \\ State.new()) do
    {:ok, settings} = SymphonyElixir.Config.delivery_observer_settings(F.fixture().config)
    row = %{"item_id" => "item-A", "state" => "Ready for agent", "eligible" => true, "archived" => false, "issue_state" => "OPEN", "native_ref" => %{"issue_id" => "issue-A", "repo" => settings.repo}}
    facts = %{"project" => %{"items" => [row]}, "open_pr_numbers" => [], "dev_sha" => G.sha(), "deployment" => G.deployment("a")}
    obs = %{complete: true, reasons: ["manual_dev_validation_required"], facts: facts}
    {%{action: "validate", actor: "local:owner", id: "form"}, obs, settings, state}
  end

  defp build({form, obs, settings, state}, action, payload, changes \\ %{}), do: Policy.build(%{form | action: action}, payload, Map.merge(obs, changes), settings, state)
  defp payload, do: %{"reason" => "Checked", "criteria" => Decision.criteria()}
  defp limits, do: %{"reason" => "Add time", "initial_minutes" => "1", "fix_minutes" => "0", "fixes" => "0", "ci_attempts" => "1", "retries_per_sha" => "0"}

  test "positive decisions require exact fresh healthy evidence, criteria and bounded payload" do
    c = setup_policy()
    {form, obs, settings, state} = c
    assert {:ok, args} = build(c, "validate", payload())
    assert args["data"]["run_id"] == 20
    assert {:error, :criteria_required} = build(c, "validate", Map.put(payload(), "criteria", []))
    assert {:error, :criteria_required} = build(c, "validate", payload(), %{facts: Map.put(obs.facts, "open_pr_numbers", [7])})
    assert {:error, :operator_reason_required} = build(c, "pause", %{"reason" => " "})
    assert {:error, :invalid_operator_payload} = Policy.build(form, [], obs, settings, state)
    assert {:error, :observation_required} = Policy.build(form, payload(), nil, settings, state)
    assert {:error, :observation_required} = build(c, "validate", payload(), %{complete: false})
    assert {:error, :remote_delivery_blocked} = build(c, "validate", payload(), %{reasons: ["artifact_expired"]})
    assert {:error, :environment_not_ready} = build(c, "validate", payload(), %{facts: Map.put(obs.facts, "deployment", %{})})
    assert {:ok, _} = Policy.build(%{form | action: "problem"}, %{"reason" => "Broken"}, nil, settings, state)
    assert {:error, :invalid_operator_payload} = build(c, "pause", %{"reason" => "x", "actor" => "bot"})
    assert Policy.stamp(obs) != Policy.stamp(put_in(obs.facts["deployment"]["run_attempt"], 2))
    assert Policy.stamp(nil) == nil
    working = G.initial() |> G.apply!("start_work", %{"interval_id" => "i", "budget" => "initial"})
    assert {:error, :work_unresolved} = build(setup_policy(working), "validate", payload())
    assert {:error, :work_unresolved} = build(setup_policy(working), "unpause", %{"reason" => "Continue"})
    assert {:error, :observation_required} = Policy.build(%{form | action: "unpause"}, %{"reason" => "Continue"}, nil, settings, state)
    assert {:ok, _} = build(c, "unpause", %{"reason" => "Allow recovery only"}, %{reasons: ["deployment_failure"], facts: Map.put(obs.facts, "deployment", %{})})
  end

  test "budget additions and recovery have explicit values and allowlisted project identity" do
    c = setup_policy(G.initial())
    assert {:ok, args} = build(c, "extend_budget", limits())
    assert args["data"]["initial_ms"] == 60_000
    assert {:error, :invalid_operator_payload} = build(c, "extend_budget", %{"reason" => "x"})
    for bad <- ["-1", "1x", "99999", nil, "1441"], do: assert({:error, :invalid_operator_budget} = build(c, "extend_budget", Map.put(limits(), "initial_minutes", bad)))
    zeros = Map.new(limits(), fn {k, _} -> {k, if(k == "reason", do: "Checked", else: "")} end)
    assert {:error, :positive_budget_required} = build(c, "extend_budget", zeros)
    recovery = Map.put(limits(), "item_id", "item-A")
    assert {:ok, args} = build(c, "recovery", recovery, %{reasons: ["deployment_failure"]})
    assert String.starts_with?(args["data"]["branch"], "agent/recovery-")
    assert {:error, :invalid_operator_payload} = build(c, "recovery", limits())
    assert {:error, :ready_allowed_item_required} = build(c, "recovery", Map.put(recovery, "item_id", "outside"))
    {form, obs, settings, state} = c
    assert {:error, :ready_allowed_item_required} = Policy.build(%{form | action: "recovery"}, recovery, obs, put_in(settings.project.item_ids, ["other"]), state)
  end

  test "resume and review retain baseline and current PR; cancellation needs closed PR" do
    c = setup_policy(G.initial())
    assert {:ok, _} = build(c, "resume", %{"reason" => "Resume"})
    assert {:error, :invalid_operator_payload} = build(c, "resume", limits())
    assert {:error, :ready_allowed_item_required} = build(setup_policy(State.new()), "resume", %{"reason" => "x"})
    {form, obs, settings, state} = setup_policy(G.reviewed())
    obs = put_in(obs.facts["pr"], %{"number" => 7, "head_sha" => G.sha("b"), "state" => "open"})
    assert {:ok, _} = Policy.build(%{form | action: "review_resume"}, limits(), obs, settings, state)
    assert {:error, :unvalidated_base} = Policy.build(%{form | action: "review_resume"}, limits(), obs, settings, %{state | "baseline" => nil})
    assert {:error, :review_context_changed} = Policy.build(%{form | action: "review_resume"}, limits(), put_in(obs.facts["pr"]["head_sha"], G.sha("c")), settings, state)
    assert {:error, :close_pr_or_validate_merged_dev} = Policy.build(%{form | action: "finish_cancel"}, %{"reason" => "Closed"}, obs, settings, state)
    obs = put_in(obs.facts["pr"]["state"], "closed")
    assert {:ok, _} = Policy.build(%{form | action: "finish_cancel"}, %{"reason" => "Closed"}, obs, settings, state)
    assert {:error, :unvalidated_base} = Policy.build(%{form | action: "finish_cancel"}, %{"reason" => "Closed"}, obs, settings, %{state | "baseline" => nil})
    assert {:error, :unvalidated_base} = Policy.build(%{form | action: "resume"}, %{"reason" => "x"}, obs, settings, %{state | "baseline" => nil})
  end

  test "safe presentation omits internal state and handles incomplete views" do
    assert View.project(nil) == nil
    refute View.project(%{gate: %{state: nil}}).available
    refute View.project(%{}).available
    assert View.label("merge") == "Неизвестное действие"

    for reason <- [
          nil,
          [:criteria_required, "manual_dev_validation_required"],
          :operator_context_changed,
          :operator_form_expired,
          :operator_reason_required,
          :ready_allowed_item_required,
          :positive_budget_required,
          :close_pr_or_validate_merged_dev,
          :environment_not_ready,
          :work_unresolved,
          "resume_queue_before_dev_validation",
          "operator_hold",
          :other,
          %{}
        ] do
      assert is_binary(View.message(reason))
    end

    {_, obs, settings, _} = setup_policy()
    obs = Map.put(obs, :observed_at, "2026-09-17T00:00:00Z")
    obs = put_in(obs.facts["repo"], "ExampleOrg/app")

    blocked = G.initial() |> G.apply!("block", %{"reason" => "x"})
    working = G.initial() |> G.apply!("start_work", %{"interval_id" => "view-i", "budget" => "initial"})
    problem = %{State.new() | "environment_problem" => %{"reason" => "Broken"}}
    paused = %{State.new() | "baseline" => G.validation(), "operator_pause" => %{"reason" => "Wait"}}

    states = [
      State.new(),
      G.initial(),
      G.ready(),
      G.reviewed(),
      blocked,
      working,
      problem,
      paused,
      G.initial() |> G.apply!("request_cancel", G.operator()),
      %{State.new() | "baseline" => G.validation()}
    ]

    for state <- states do
      status = %{
        # Every lifecycle phase uses the same observed deployment.
        gate: %{state: state},
        observation: obs,
        observation_age_ms: 0,
        reason: nil,
        worker: nil,
        restart_required: false
      }

      view = View.project(status)
      assert view.available and not view.execution_enabled
      refute Map.has_key?(view, :gate)
      assert view.run_url == "https://github.com/ExampleOrg/app/actions/runs/20"

      if state == working do
        assert view.budget.remaining["initial_ms"] == 0
        assert view.budget.reserved == 3_600_000
        assert view.budget.ci_remaining == 6
      end
    end

    context = %{observation: obs, settings: settings, gate: %{state: G.initial()}}
    form = Map.put(View.form(context), :action, "recovery")
    assert form.choices == ["item-A"]
    assert View.preview(form, limits()).preview["initial_ms"] == 60_000
    assert View.preview(%{form | action: "extend_budget"}, %{"initial_minutes" => "bad"}).preview == form.limits

    for deployment <- [%{}, %{"queue" => %{"reason" => "inherited_pause"}}] do
      status = %{gate: %{state: State.new()}, observation: put_in(obs.facts["deployment"], deployment), observation_age_ms: 0, reason: nil, worker: nil, restart_required: false}
      assert View.project(status).readiness != ""
    end
  end
end
