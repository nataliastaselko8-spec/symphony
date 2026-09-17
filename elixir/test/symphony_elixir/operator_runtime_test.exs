defmodule SymphonyElixir.OperatorRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}
  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.{Observation, QueueConfirmation}
  alias SymphonyElixir.Operator.{Auth, Control, Credential, Decision}

  setup do
    root = Path.join(System.tmp_dir!(), "operator-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "token")
    :ok = Credential.create(path)
    auth = start_supervised!({Auth, settings: %{principal: "local:owner", credential_path: path, origin: "http://127.0.0.1:4080"}})
    {:ok, session} = Auth.login(auth, File.read!(path) |> String.trim())
    config = put_in(F.fixture().config.delivery.state_path, Path.join(root, "state.json")).config
    {:ok, settings} = Config.delivery_observer_settings(config)
    gate = start_supervised!({DeliveryGate, settings: settings.gate})
    tasks = start_supervised!(Task.Supervisor)
    clock = start_supervised!({Agent, fn -> 0 end}, id: :clock)
    facts = %{"repo" => settings.repo, "project" => %{"items" => []}, "open_pr_numbers" => [], "dev_sha" => G.sha(), "deployment" => G.deployment("a"), "watch_digest" => String.duplicate("a", 64)}
    remote = start_supervised!({Agent, fn -> {:facts, facts} end}, id: :remote)

    observer = fn _, opts ->
      case Agent.get(remote, & &1) do
        {:facts, current} ->
          {:ok, Observation.new(settings, opts[:context], current, ["manual_dev_validation_required"])}

        {:delay, current, parent} ->
          send(parent, {:observer_waiting, self()})

          receive do
            :continue -> {:ok, Observation.new(settings, opts[:context], current, ["manual_dev_validation_required"])}
          end

        :error ->
          {:error, :github_delivery_unavailable}
      end
    end

    runtime =
      start_supervised!(
        {DeliveryRuntime,
         config: config,
         gate: gate,
         task_supervisor: tasks,
         observer: observer,
         watch: fn _, _, _, _ -> :ok end,
         poll_ms: 0,
         now: fn -> Agent.get(clock, & &1) end,
         wall_now: fn -> 1_800_000_000_000 + Agent.get(clock, & &1) end}
      )

    await(runtime)

    %{
      root: root,
      auth: auth,
      session: session,
      gate: gate,
      runtime: runtime,
      remote: remote,
      facts: facts,
      clock: clock,
      settings: settings
    }
  end

  defp await(runtime, attempts \\ 500)
  defp await(_, 0), do: flunk("observation did not settle")

  defp await(runtime, n) do
    status = DeliveryRuntime.status(runtime)

    if status.observation && status.observation.expected_version == status.gate.version,
      do: status,
      else:
        (
          Process.sleep(10)
          await(runtime, n - 1)
        )
  end

  defp prepare(c, action), do: Control.prepare(c.auth, c.session, c.runtime, action)
  defp submit(c, form, params), do: Control.execute(c.auth, c.session, form.id, params)
  defp validation, do: %{"reason" => "Manual check passed", "criteria" => Decision.criteria()}

  defp queue_payload, do: %{"reason" => "Resumed dev queue", "criteria" => QueueConfirmation.criteria(), "queue_resource" => "dev-delivery", "scheduler_resource" => "dev-scheduler"}

  defp inherited(c) do
    deployment =
      Map.merge(c.facts["deployment"], %{
        "environment_ready" => false,
        "complete" => true,
        "source" => "deployment_evidence",
        "blockers" => ["resume_queue_before_dev_validation"],
        "queue" => %{"state" => "paused", "reason" => "inherited_pause"},
        "scheduler" => "configured",
        "artifact_id" => 10,
        "digest" => "sha256:" <> String.duplicate("a", 64)
      })

    facts = Map.merge(c.facts, %{"deployment" => deployment, "policy_hashes" => %{"workflow" => String.duplicate("a", 64)}})
    Agent.update(c.remote, fn _ -> {:facts, facts} end)
    DeliveryRuntime.refresh(c.runtime)
    # Wait for this new remote value, not merely a previously settled revision.
    wait_queue(c.runtime)
    facts
  end

  defp wait_queue(runtime, attempts \\ 500)
  defp wait_queue(_, 0), do: flunk("queue observation not ready")

  defp wait_queue(runtime, attempts) do
    status = await(runtime)

    if get_in(status.observation.facts, ["deployment", "queue", "reason"]) == "inherited_pause",
      do: status,
      else:
        (
          # The fixture clock is stationary. An initial read may have captured
          # older facts before refresh; explicitly request the next settled read.
          DeliveryRuntime.refresh(runtime)
          Process.sleep(10)
          wait_queue(runtime, attempts - 1)
        )
  end

  test "manual Queue confirmation is durable, idempotent and separate from validation and pause", c do
    inherited(c)
    {:ok, pause} = prepare(c, "pause")
    assert {:ok, _} = submit(c, pause, %{"reason" => "Keep task queue paused"})
    await(c.runtime)
    {:ok, form} = prepare(c, "confirm_queue")
    assert {:ok, %{replayed: false}} = submit(c, form, queue_payload())
    assert {:ok, %{replayed: true}} = submit(c, form, queue_payload())
    status = await(c.runtime)
    assert status.observation.facts["deployment"]["environment_ready"]
    assert status.gate.state["baseline"] == nil
    refute status.gate.state["queue_confirmation"]["validated"]
    bootstrap(c)
    state = DeliveryGate.status(c.gate).state
    assert state["queue_confirmation"]["validated"]
    assert state["operator_pause"] != nil
    assert state["queue_confirmation"]["confirmed_at_ms"] == 1_800_000_000_000
    stop_supervised!(DeliveryRuntime)
    stop_supervised!(DeliveryGate)
    gate = start_supervised!({DeliveryGate, settings: c.settings.gate})
    assert DeliveryGate.status(gate).state["queue_confirmation"] == state["queue_confirmation"]
  end

  test "expired Queue testimony rejects an open validation form; new proof cannot reuse it", c do
    facts = inherited(c)
    {:ok, form} = prepare(c, "confirm_queue")
    assert {:ok, _} = submit(c, form, queue_payload())
    await(c.runtime)
    {:ok, validation_form} = prepare(c, "validate")
    Agent.update(c.clock, fn _ -> 1_800_000 end)
    assert {:error, :operator_context_changed} = submit(c, validation_form, validation())
    refute DeliveryRuntime.status(c.runtime).observation.facts["deployment"]["environment_ready"]
    DeliveryRuntime.refresh(c.runtime)
    # Full observation durably removes expired evidence.
    wait_confirmation_removed(c.runtime)
    {:ok, refreshed} = prepare(c, "confirm_queue")
    assert {:ok, _} = submit(c, refreshed, queue_payload())
    await(c.runtime)
    {:ok, form} = prepare(c, "validate")
    Agent.update(c.remote, fn _ -> {:facts, put_in(facts, ["deployment", "run_attempt"], 2)} end)
    assert {:error, :operator_context_changed} = submit(c, form, validation())
    DeliveryRuntime.refresh(c.runtime)
    wait_confirmation_removed(c.runtime)
    assert DeliveryGate.status(c.gate).state["baseline"] == nil
  end

  test "real merged cycle remains owned until Queue then dev validation; old artifact polls preserve testimony", c do
    options = :sys.get_state(c.runtime).opts
    stop_supervised!(DeliveryRuntime)

    for {action, args, sha} <- [
          {"bootstrap", G.validation(), G.sha()},
          {"reserve", G.task(), G.sha()},
          {"reserve_ci", G.ci_request(), G.sha()},
          {"observe_ci", G.ci_result(), G.sha()},
          {"handoff", %{"pr_number" => 7, "sha" => G.sha("b")}, G.sha()},
          {"merged", %{"pr_number" => 7, "sha" => G.sha("c")}, G.sha("c")}
        ] do
      current = DeliveryGate.status(c.gate)
      unless action == "observe_ci", do: :ok = DeliveryGate.reconcile(c.gate, current.version, c.settings.gate.scope, sha)
      assert {:ok, _} = DeliveryGate.execute(c.gate, current.version, "seed-" <> action, action, args)
    end

    runtime = start_supervised!({DeliveryRuntime, options})

    c = %{
      c
      | runtime: runtime,
        facts: Map.merge(c.facts, %{"dev_sha" => G.sha("c"), "deployment" => G.deployment(), "pr" => %{"number" => 7, "state" => "merged", "merge_sha" => G.sha("c"), "ancestry" => "included"}})
    }

    inherited(c)
    {:ok, form} = prepare(c, "confirm_queue")
    assert {:ok, _} = submit(c, form, queue_payload())
    status = await(runtime)
    assert status.gate.state["cycle"]["owner"]["item_id"] == "item-A"
    assert status.gate.state["cycle"]["phase"] == "awaiting_validation"
    bootstrap(c)
    assert DeliveryGate.status(c.gate).state["cycle"] == nil
    Agent.update(c.clock, fn _ -> 3_600_000 end)
    DeliveryRuntime.refresh(runtime)
    status = await(runtime)
    assert status.observation.facts["deployment"]["environment_ready"]
    assert status.gate.state["queue_confirmation"]["validated"]
  end

  defp wait_confirmation_removed(runtime, attempts \\ 500)
  defp wait_confirmation_removed(_, 0), do: flunk("queue evidence not invalidated")

  defp wait_confirmation_removed(runtime, attempts) do
    status = await(runtime)

    if status.gate.state["queue_confirmation"] == nil,
      do: status,
      else:
        (
          Process.sleep(10)
          wait_confirmation_removed(runtime, attempts - 1)
        )
  end

  defp bootstrap(c) do
    {:ok, form} = prepare(c, "validate")
    assert {:ok, _} = submit(c, form, validation())
    await(c.runtime)
  end

  test "initial validation uses real store, duplicate submit is one record, pause survives restart", c do
    {:ok, form} = prepare(c, "validate")
    assert {:ok, %{replayed: false}} = submit(c, form, validation())
    assert {:ok, %{replayed: true}} = submit(c, form, validation())
    assert {:error, :command_id_reused} = submit(c, form, Map.put(validation(), "reason", "Changed"))
    assert length(DeliveryGate.decisions(c.gate)) == 1
    assert DeliveryGate.status(c.gate).state["status"] == "idle"
    await(c.runtime)
    {:ok, pause} = prepare(c, "pause")
    Agent.update(c.remote, fn _ -> :error end)
    assert {:ok, _} = submit(c, pause, %{"reason" => "Maintenance"})
    assert DeliveryGate.status(c.gate).state["operator_pause"]["actor"] == "local:owner"
    stop_supervised!(DeliveryRuntime)
    stop_supervised!(DeliveryGate)
    gate = start_supervised!({DeliveryGate, settings: c.settings.gate})
    assert DeliveryGate.status(gate).state["operator_pause"]["reason"] == "Maintenance"
    assert length(DeliveryGate.decisions(gate)) == 2
    assert {:error, :delivery_runtime_unavailable} = submit(c, pause, %{"reason" => "Maintenance"})
  end

  test "new deployment attempt or dev commit invalidates a form even without state revision", c do
    {:ok, form} = prepare(c, "validate")
    revision = DeliveryGate.status(c.gate).version

    for updated <- [put_in(c.facts, ["deployment", "run_attempt"], 2), Map.put(c.facts, "dev_sha", G.sha("b"))] do
      Agent.update(c.remote, fn _ -> {:facts, updated} end)
      assert {:error, :operator_context_changed} = submit(c, form, validation())
      assert DeliveryGate.status(c.gate).version == revision
    end

    Agent.update(c.remote, fn _ -> :error end)
    assert {:error, :github_delivery_unavailable} = submit(c, form, validation())
  end

  test "pause wins while a validation read is pending; stale positive operation cannot clear it", c do
    {:ok, form} = prepare(c, "validate")
    parent = self()
    Agent.update(c.remote, fn _ -> {:delay, c.facts, parent} end)
    pending = Task.async(fn -> submit(c, form, validation()) end)
    assert_receive {:observer_waiting, reader}, 2_000
    {:ok, pause} = prepare(c, "pause")
    assert {:ok, _} = submit(c, pause, %{"reason" => "Stop now"})
    Agent.update(c.remote, fn _ -> {:facts, c.facts} end)
    send(reader, :continue)
    assert {:error, :operator_context_changed} = Task.await(pending)
    assert DeliveryGate.status(c.gate).state["baseline"] == nil
    assert DeliveryGate.status(c.gate).state["operator_pause"] != nil
  end

  test "session logout during observation rejects an already started request", c do
    {:ok, form} = prepare(c, "validate")
    parent = self()
    Agent.update(c.remote, fn _ -> {:delay, c.facts, parent} end)
    pending = Task.async(fn -> submit(c, form, validation()) end)
    assert_receive {:observer_waiting, reader}, 2_000
    assert :ok = Auth.logout(c.auth, c.session)
    send(reader, :continue)
    assert {:error, :operator_login_required} = Task.await(pending)
    assert DeliveryGate.decisions(c.gate) == []
  end

  test "unknown action, forged principal, another session, and stale revision cannot mutate state", c do
    assert {:error, :unknown_operator_action} = prepare(c, "merged")
    assert {:error, :operator_login_required} = Control.prepare(c.auth, "missing", c.runtime, "pause")
    {:ok, form} = prepare(c, "pause")
    assert {:error, :invalid_operator_payload} = submit(c, form, %{"reason" => "x", "actor" => "bot"})
    assert {:error, :operator_form_expired} = Control.execute(c.auth, c.session, "missing", %{})
    {:ok, other} = Auth.prepare(c.auth, c.session, %{runtime: c.gate, action: "pause"})
    assert {:error, :operator_form_invalid} = DeliveryRuntime.operator_apply(c.runtime, c.auth, c.session, other.id, %{}, nil, 0)
    bootstrap(c)
    assert {:error, :operator_context_changed} = submit(c, form, %{"reason" => "old"})
  end

  test "negative report is durable without a task; validation clears problem but never pause", c do
    {:ok, problem} = prepare(c, "problem")
    assert {:ok, _} = submit(c, problem, %{"reason" => "App unavailable"})
    await(c.runtime)
    {:ok, pause} = prepare(c, "pause")
    assert {:ok, _} = submit(c, pause, %{"reason" => "Maintenance"})
    await(c.runtime)
    bootstrap(c)
    state = DeliveryGate.status(c.gate).state
    assert state["environment_problem"] == nil
    assert state["operator_pause"] != nil
    {:ok, unpause} = prepare(c, "unpause")
    assert {:ok, _} = submit(c, unpause, %{"reason" => "Resume checked queue"})
    assert DeliveryGate.status(c.gate).state["operator_pause"] == nil
  end

  test "a delayed read expires; auth unavailable and runtime unavailable fail closed", c do
    {:ok, form} = prepare(c, "validate")
    parent = self()
    Agent.update(c.remote, fn _ -> {:delay, c.facts, parent} end)
    pending = Task.async(fn -> submit(c, form, validation()) end)
    assert_receive {:observer_waiting, reader}, 2_000
    Agent.update(c.clock, fn _ -> 1_000_000 end)
    send(reader, :continue)
    assert {:error, :operator_context_changed} = Task.await(pending)
    assert {:error, :delivery_runtime_unavailable} = DeliveryRuntime.operator_context(:missing_runtime)
    assert {:error, :operator_auth_unavailable} = Control.prepare(:missing_auth, c.session, c.runtime, "pause")
  end

  test "unpause retains a reported problem and does not require an already repaired deployment", c do
    broken = put_in(c.facts, ["deployment", "result"], "failure")
    Agent.update(c.remote, fn _ -> {:facts, broken} end)
    DeliveryRuntime.refresh(c.runtime)
    await(c.runtime)
    {:ok, problem} = prepare(c, "problem")
    assert {:ok, _} = submit(c, problem, %{"reason" => "Broken deployment"})
    await(c.runtime)
    {:ok, pause} = prepare(c, "pause")
    assert {:ok, _} = submit(c, pause, %{"reason" => "Inspect"})
    await(c.runtime)
    {:ok, form} = prepare(c, "unpause")
    assert {:ok, _} = submit(c, form, %{"reason" => "Recovery may be assigned separately"})
    state = DeliveryGate.status(c.gate).state
    assert state["operator_pause"] == nil
    assert state["environment_problem"] != nil
    assert state["baseline"] == nil
    assert Decision.held?(state)
  end

  test "observation binding errors and unverified store never authorize an operator decision", c do
    assert %{state: :delivery_runtime_redacted} = DeliveryRuntime.format_status(%{})
    {:ok, form} = prepare(c, "validate")
    status = DeliveryRuntime.status(c.runtime)
    bad = %{status.observation | scope: %{}}
    assert {:error, :observation_scope_changed} = DeliveryRuntime.operator_apply(c.runtime, c.auth, c.session, form.id, validation(), bad, 0)
    path = Path.join(c.root, "damaged.json")
    File.write!(path, "not a snapshot")
    File.chmod!(path, 0o600)
    gate = start_supervised!({DeliveryGate, settings: %{c.settings.gate | path: path}}, id: :damaged_gate)
    assert DeliveryGate.status(gate).state == nil
    assert DeliveryGate.decisions(gate) == []
    assert DeliveryGate.decision(gate, "missing") == nil
  end
end
