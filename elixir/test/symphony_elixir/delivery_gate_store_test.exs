defmodule SymphonyElixir.DeliveryGateStoreTest do
  use ExUnit.Case, async: true
  @moduletag skip: :os.type() != {:unix, :linux}

  alias SymphonyElixir.{Config, DeliveryGate}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DeliveryGate.Store
  import SymphonyElixir.DeliveryGateSupport

  setup do
    root = Path.join(System.tmp_dir!(), "delivery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    settings = %{path: Path.join(root, "cycle.json"), scope: %{"repo" => "example/app", "project_number" => 1}}
    on_exit(fn -> File.rm_rf!(root) end)
    %{settings: settings, root: root}
  end

  defp start_gate(settings) do
    {:ok, pid} = DeliveryGate.start_link(settings: settings)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp version(pid), do: DeliveryGate.status(pid).version

  defp execute(pid, settings, action, args, id \\ nil) do
    DeliveryGate.reconcile(pid, version(pid), settings.scope, args["sha"] || sha())
    DeliveryGate.execute(pid, version(pid), id || "cmd-#{System.unique_integer([:positive])}", action, args)
  end

  defp boot(settings) do
    pid = start_gate(settings)
    assert {:ok, _} = execute(pid, settings, "bootstrap", validation(), "boot")
    assert {:ok, _} = execute(pid, settings, "reserve", task(), "reserve")
    pid
  end

  test "no implicit bootstrap, stale epoch and settings switches cannot open the queue", %{settings: settings} do
    pid = start_gate(settings)
    original = version(pid)
    refute File.exists?(settings.path)
    assert DeliveryGate.status(pid).mode == :bootstrap_required
    assert {:error, :reconciliation_required} = DeliveryGate.admission(pid, original, "new")
    assert {:error, :reconciliation_required} = DeliveryGate.execute(pid, original, "boot", "bootstrap", validation())
    assert :ok = DeliveryGate.check_settings(pid, settings)
    assert {:error, :restart_required} = DeliveryGate.check_settings(pid, %{settings | path: settings.path <> "-new"})
    assert {:error, :reconciliation_incomplete} = DeliveryGate.reconcile(pid, original, %{}, sha())
    assert :ok = DeliveryGate.reconcile(pid, original, settings.scope, sha())
    assert {:error, :observation_sha_changed} = DeliveryGate.execute(pid, original, "wrong", "bootstrap", validation("b"))
    assert {:ok, %{replayed: false}} = DeliveryGate.execute(pid, original, "boot", "bootstrap", validation())
    assert File.exists?(settings.path)
    assert {:ok, %{replayed: true}} = DeliveryGate.execute(pid, original, "boot", "bootstrap", validation())
    assert {:error, :stale_revision} = DeliveryGate.execute(pid, original, "other", "reserve", task())
    assert {:error, :stale_version} = DeliveryGate.execute(pid, %{original | epoch: "old"}, "other", "reserve", task())
    assert {:error, :stale_version} = DeliveryGate.admission(pid, original, "new")
    assert {:error, :stale_version} = DeliveryGate.reconcile(pid, original, settings.scope, sha())
    assert :ok = DeliveryGate.reconcile(pid, version(pid), settings.scope, sha("c"))
    assert {:error, :unvalidated_base} = DeliveryGate.admission(pid, version(pid), "new")
  end

  test "state and budgets survive restart but old commands and old readiness do not", %{settings: settings} do
    pid = boot(settings)
    assert {:ok, _} = execute(pid, settings, "start_work", %{"interval_id" => "s", "budget" => "initial"})
    assert {:ok, _} = execute(pid, settings, "checkpoint", %{"interval_id" => "s", "elapsed_ms" => 12_345})
    old = version(pid)
    GenServer.stop(pid)
    restarted = start_gate(settings)
    status = DeliveryGate.status(restarted)
    assert status.state["cycle"]["owner"]["item_id"] == "item-A"
    assert status.state["cycle"]["budget"]["initial_ms"] == 12_345
    assert status.mode == :needs_reconciliation
    assert status.version.epoch != old.epoch
    assert {:error, :stale_version} = DeliveryGate.execute(restarted, old, "next", "block", %{"reason" => "x"})
    assert {:error, :reconciliation_incomplete} = DeliveryGate.reconcile(restarted, version(restarted), settings.scope, sha())
    assert {:ok, _} = execute(restarted, settings, "resolve_interval", Map.merge(operator(), %{"interval_id" => "s", "elapsed_ms" => 13_000}))
    assert DeliveryGate.status(restarted).state["cycle"]["budget"]["initial_ms"] == 3_600_000
    assert :ok = DeliveryGate.reconcile(restarted, version(restarted), settings.scope, sha())
    assert {:error, :cycle_blocked} = DeliveryGate.admission(restarted, version(restarted), "new")
  end

  test "kernel lock prevents two controller processes from owning the same file", %{settings: settings} do
    pid = boot(settings)
    assert {:error, :store_operation_failed} = Store.open(settings.path)
    assert DeliveryGate.status(pid).state["cycle"]["id"] == "cycle-A"
    GenServer.stop(pid)
    assert {:ok, port} = Store.open(settings.path)
    assert {:ok, snapshot} = Store.request(port, %{"op" => "read"})
    assert snapshot["state"]["cycle"]["id"] == "cycle-A"
    Store.close(port)
  end

  test "admission checks the persisted file and rejects replacement with a valid older snapshot", %{settings: settings} do
    pid = boot(settings)
    assert :ok = DeliveryGate.reconcile(pid, version(pid), settings.scope, sha())
    assert :ok = DeliveryGate.admission(pid, version(pid), "item-A")
    File.write!(settings.path, File.read!(settings.path <> ".previous"))
    assert {:error, :store_changed} = DeliveryGate.admission(pid, version(pid), "item-A")
    assert DeliveryGate.status(pid).mode == :store_unavailable
  end

  test "an unavailable store prevents starting the controller", %{settings: settings} do
    Process.flag(:trap_exit, true)
    assert {:error, :store_operation_failed} = DeliveryGate.start_link(settings: %{settings | path: "relative.json"})
  end

  test "a stalled or disconnected storage process cannot acknowledge a command" do
    python = System.find_executable("python3")
    Process.flag(:trap_exit, true)
    stalled = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :use_stdio, {:args, ["-I", "-c", "import sys; sys.stdin.buffer.read()"]}])
    assert {:error, :store_timeout} = Store.request(stalled, %{"op" => "read"})
    gone = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :use_stdio, {:args, ["-I", "-c", "import sys; sys.stdin.buffer.read(4)"]}])
    assert {:error, :store_unavailable} = Store.request(gone, %{"op" => "read"})
    failed = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :use_stdio, :exit_status, {:args, ["-I", "-c", "import sys; sys.stdin.buffer.read(4); sys.exit(42)"]}])
    assert {:error, :store_unavailable} = Store.request(failed, %{"op" => "read"})
    assert {:error, :store_unavailable} = Store.request({}, %{"op" => "read"})
  end

  test "helper death while idle is observed without a subsequent write", %{settings: settings} do
    pid = boot(settings)
    port = :sys.get_state(pid).port
    reference = :erlang.monitor(:port, port)
    {:os_pid, child_pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(child_pid)])
    assert_receive {:DOWN, ^reference, :port, ^port, _}, 1000
    assert DeliveryGate.status(pid).mode == :store_unavailable
  end

  test "concurrent reservations with the same version have one winner", %{settings: settings} do
    pid = start_gate(settings)
    assert {:ok, _} = execute(pid, settings, "bootstrap", validation())
    assert :ok = DeliveryGate.reconcile(pid, version(pid), settings.scope, sha())
    expected = version(pid)
    results = 1..8 |> Enum.map(fn n -> Task.async(fn -> DeliveryGate.execute(pid, expected, "reserve-#{n}", "reserve", %{task() | "cycle_id" => "cycle-#{n}"}) end) end) |> Task.await_many()
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :stale_revision}, &1)) == 7
  end

  test "corrupt current file requires explicit backup recovery and new reconciliation", %{settings: settings} do
    pid = boot(settings)
    assert {:ok, _} = execute(pid, settings, "block", %{"reason" => "manual_pause"})
    old_version = version(pid)
    GenServer.stop(pid)
    File.write!(settings.path, "broken json")
    pid = start_gate(settings)
    assert DeliveryGate.status(pid).mode == :recovery_required
    assert {:error, :recovery_required} = DeliveryGate.execute(pid, version(pid), "boot", "bootstrap", validation())
    assert {:error, :restore_failed} = DeliveryGate.restore_backup(pid, old_version, "operator", "reviewed")
    assert {:error, :restore_failed} = DeliveryGate.restore_backup(pid, version(pid), "", "reviewed")
    assert :ok = DeliveryGate.restore_backup(pid, version(pid), "operator", "Compared backup with repository state")
    assert DeliveryGate.status(pid).mode == :needs_reconciliation
    assert DeliveryGate.status(pid).state["cycle"]["id"] == "cycle-A"
    assert {:error, :reconciliation_required} = DeliveryGate.admission(pid, version(pid), "new")
    assert length(Path.wildcard(settings.path <> ".quarantine-*")) == 1
    assert {:error, :restore_failed} = DeliveryGate.restore_backup(pid, version(pid), "operator", "again")
  end

  test "missing previously initialized file is not a fresh repository", %{settings: settings} do
    pid = boot(settings)
    GenServer.stop(pid)
    File.rm!(settings.path)
    pid = start_gate(settings)
    assert DeliveryGate.status(pid).mode == :recovery_required
    assert {:error, :reconciliation_incomplete} = DeliveryGate.reconcile(pid, version(pid), settings.scope, sha())
    assert {:error, :recovery_required} = DeliveryGate.execute(pid, version(pid), "reset", "bootstrap", validation())
  end

  test "changed scope rejects both head and backup instead of silently resetting", %{settings: settings} do
    pid = boot(settings)
    GenServer.stop(pid)
    different = %{settings | scope: %{"repo" => "other/app"}}
    pid = start_gate(different)
    assert DeliveryGate.status(pid).mode == :recovery_required
    assert {:error, :restore_failed} = DeliveryGate.restore_backup(pid, version(pid), "operator", "different repo")
  end

  test "write failure does not acknowledge an action or leave admission enabled", %{settings: settings} do
    pid = boot(settings)
    before = DeliveryGate.status(pid)
    File.write!(settings.path, "external edit")
    assert {:error, :store_operation_failed} = execute(pid, settings, "request_cancel", operator())
    status = DeliveryGate.status(pid)
    assert status.state == before.state
    assert status.mode == :store_unavailable
    assert {:error, :reconciliation_required} = DeliveryGate.admission(pid, version(pid), "new")
    assert {:error, :store_unavailable} = execute(pid, settings, "block", %{"reason" => "x"})
  end

  test "loss of the helper process invalidates admission immediately", %{settings: settings} do
    pid = boot(settings)
    port = :sys.get_state(pid).port
    {:os_pid, child_pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(child_pid)])
    assert {:error, _} = execute(pid, settings, "block", %{"reason" => "test helper loss"})
    assert DeliveryGate.status(pid).mode == :store_unavailable
    assert {:error, :store_unavailable} = Store.request(port, %{"op" => "read"})
    send(pid, :unrelated_message)
    assert DeliveryGate.status(pid).mode == :store_unavailable
  end

  test "store files are private and unsafe symlinks and permissions are rejected", %{settings: settings, root: root} do
    pid = boot(settings)

    for path <- [settings.path, settings.path <> ".lock", settings.path <> ".previous"] do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    GenServer.stop(pid)
    File.chmod!(root, 0o755)
    assert {:error, :store_operation_failed} = Store.open(settings.path)
    File.chmod!(root, 0o700)
    link = Path.join(root, "link.json")
    File.ln_s!(settings.path, link)
    assert {:error, :store_operation_failed} = Store.open(link)
    assert {:error, :store_operation_failed} = Store.open("relative.json")
  end

  test "configuration creates no state and binds a secret-free immutable scope", %{root: root} do
    config = %{
      "tracker" => %{"kind" => "github_projects", "provider" => %{"organization" => "Example", "repo" => "Example/app", "project_number" => 1, "token" => "secret-one"}},
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "delivery" => %{"state_path" => Path.join(root, "state/cycle.json")}
    }

    assert {:ok, schema} = Schema.parse(config)
    assert {:ok, settings} = Config.delivery_settings(schema)
    refute File.exists?(settings.path)
    refute Jason.encode!(settings.scope) =~ "secret"
    assert settings.scope["repo"] == "example/app"
    assert {:ok, rotated} = Schema.parse(put_in(config, ["tracker", "provider", "token"], "secret-two"))
    assert {:ok, ^settings} = Config.delivery_settings(rotated)

    for path <- [
          nil,
          "relative.json",
          "/mnt/d/state.json",
          root <> "/../cycle.json",
          Path.join(root, "workspaces/state.json"),
          Path.join(root, "workspaces"),
          "/home/test/a\\b",
          "/home/test/" <> <<0>>
        ] do
      assert {:ok, invalid} = Schema.parse(put_in(config, ["delivery", "state_path"], path))
      assert {:error, :invalid_delivery_state_path} = Config.delivery_settings(invalid)
    end

    assert {:ok, other} = Schema.parse(put_in(config, ["tracker", "kind"], "linear"))
    assert {:error, :delivery_requires_github_projects} = Config.delivery_settings(other)
    assert {:ok, other} = Schema.parse(put_in(config, ["tracker", "provider", "repo"], "other/app"))
    assert {:error, :invalid_delivery_scope} = Config.delivery_settings(other)
    assert {:error, _} = Schema.parse(put_in(config, ["delivery", "base_branch"], "bad branch"))
  end

  test "App identity changes scope but rotating its key path does not read or reset state", %{root: root} do
    app = %{"app_id" => "1", "installation_id" => "2", "private_key_path" => "/private/example-not-present.pem"}

    config = %{
      "tracker" => %{
        "kind" => "github_projects",
        "provider" => %{
          "organization" => "Example",
          "repo" => "Example/app",
          "project_number" => 1,
          "github_app" => app
        }
      },
      "delivery" => %{"state_path" => Path.join(root, "state/cycle.json")}
    }

    assert {:ok, schema} = Schema.parse(config)
    assert {:ok, first} = Config.delivery_settings(schema)
    rotated_config = put_in(config, ["tracker", "provider", "github_app", "private_key_path"], "/private/rotated.pem")
    assert {:ok, schema} = Schema.parse(rotated_config)
    assert {:ok, ^first} = Config.delivery_settings(schema)
    changed_config = put_in(config, ["tracker", "provider", "github_app", "installation_id"], "3")
    assert {:ok, schema} = Schema.parse(changed_config)
    assert {:ok, different} = Config.delivery_settings(schema)
    refute first.scope == different.scope
    refute Jason.encode!(first.scope) =~ "private"
    assert {:ok, invalid} = Schema.parse(put_in(config, ["tracker", "provider", "github_app", "app_id"], nil))
    assert {:error, :invalid_github_app_id} = Config.delivery_settings(invalid)
  end
end
