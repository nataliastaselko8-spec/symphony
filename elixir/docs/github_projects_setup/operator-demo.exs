# Isolated PR-10 demonstration: actual Auth/Runtime/Gate, synthetic observations only.
# Run from elixir: MIX_ENV=test mise exec -- mix run --no-start docs/github_projects_setup/operator-demo.exs
unless Mix.env() == :test, do: raise("Use MIX_ENV=test; this script never loads your runtime workflow")

Code.require_file("../../test/support/delivery_gate_support.exs", __DIR__)
Code.require_file("../../test/support/delivery_observer_support.exs", __DIR__)

alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
alias SymphonyElixir.DeliveryGateSupport, as: G
alias SymphonyElixir.DeliveryObserverSupport, as: F
alias SymphonyElixir.GitHubProjects.Delivery.Observation
alias SymphonyElixir.Operator.Auth
alias SymphonyElixirWeb.Endpoint

{:ok, _} = Application.ensure_all_started(:phoenix_live_view)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:ecto)
{:ok, _} = Application.ensure_all_started(:yaml_elixir)

root = Path.join(System.tmp_dir!(), "symphony-operator-demo-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}")
:ok = File.mkdir(root)
:ok = File.chmod(root, 0o700)
credential_path = Path.join(root, "demo-token")
# Public fixture password, intentionally usable only with synthetic data on this demo server.
password = Base.url_encode64(String.duplicate("demo-only-", 4), padding: false)
:ok = File.write(credential_path, password)
:ok = File.chmod(credential_path, 0o600)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: SymphonyElixir.PubSub}], strategy: :one_for_one)
{:ok, tasks} = Task.Supervisor.start_link()
{:ok, auth} = Auth.start_link(settings: %{principal: "local:demo", credential_path: credential_path, origin: "http://localhost:4081"})

config = put_in(F.fixture().config.delivery.state_path, Path.join(root, "state.json")).config
{:ok, settings} = Config.delivery_observer_settings(config)
{:ok, gate} = DeliveryGate.start_link(settings: settings.gate)

for {command, args, dev} <- [
      {"bootstrap", G.validation(), G.sha()},
      {"reserve", G.task(), G.sha()},
      {"reserve_ci", G.ci_request(), G.sha()},
      {"observe_ci", G.ci_result(), G.sha()},
      {"handoff", %{"pr_number" => 7, "sha" => G.sha("b")}, G.sha()},
      {"merged", %{"pr_number" => 7, "sha" => G.sha("c")}, G.sha("c")},
      {"deployment", G.deployment(), G.sha("c")}
    ] do
  current = DeliveryGate.status(gate)
  unless command == "observe_ci", do: :ok = DeliveryGate.reconcile(gate, current.version, settings.gate.scope, dev)
  {:ok, _} = DeliveryGate.execute(gate, current.version, "demo-#{command}", command, args)
end

observer = fn _, opts ->
  cycle = opts[:context].state["cycle"]
  pr = if cycle, do: %{"number" => 7, "head_sha" => G.sha("b"), "state" => "merged", "merge_sha" => G.sha("c"), "ancestry" => "included"}
  deployment = Map.merge(G.deployment(), %{"environment_ready" => false, "complete" => true, "source" => "deployment_evidence", "queue" => %{"state" => "paused", "reason" => "inherited_pause"}, "scheduler" => "configured", "blockers" => ["resume_queue_before_dev_validation"], "artifact_id" => 10, "digest" => "sha256:" <> String.duplicate("a", 64)})
  row = %{"item_id" => "item-R", "eligible" => true, "archived" => false, "issue_state" => "OPEN", "state" => "Ready for agent", "native_ref" => %{"repo" => settings.repo, "issue_id" => "issue-R"}}
  facts = %{"repo" => settings.repo, "dev_sha" => G.sha("c"), "deployment" => deployment, "policy_hashes" => %{"workflow" => String.duplicate("a", 64)}, "pr" => pr, "project" => %{"items" => [row]}, "open_pr_numbers" => [], "watch_digest" => String.duplicate("a", 64)}
  {:ok, Observation.new(settings, opts[:context], facts, ["manual_dev_validation_required"])}
end

{:ok, runtime} = DeliveryRuntime.start_link(config: config, gate: gate, task_supervisor: tasks, observer: observer, poll_ms: 5_000)
endpoint = Application.get_env(:symphony_elixir, Endpoint, [])
endpoint = Keyword.merge(endpoint,
  server: true, http: [ip: {127, 0, 0, 1}, port: 4081], url: [host: "localhost", port: 4081],
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)), check_origin: ["http://localhost:4081"],
  operator_enabled: true, operator_demo: true, operator_auth: auth, operator_runtime: runtime,
  orchestrator: :demo_no_agent_orchestrator, snapshot_timeout_ms: 5)
Application.put_env(:symphony_elixir, Endpoint, endpoint)
{:ok, _} = Endpoint.start_link()
IO.puts("DEMO ONLY: http://localhost:4081/operator/login\nPublic demo password: #{password}\nDisposable state: #{root}\nCtrl+C twice to stop.")
Process.sleep(:infinity)
