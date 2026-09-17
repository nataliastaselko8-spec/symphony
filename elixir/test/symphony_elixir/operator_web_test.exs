defmodule SymphonyElixir.OperatorWebTest do
  use ExUnit.Case, async: false
  @moduletag skip: :os.type() != {:unix, :linux}
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mix.Tasks.Operator.Setup
  alias SymphonyElixir.{Config, DeliveryGate, DeliveryRuntime}
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.Observation
  alias SymphonyElixir.Operator.{Auth, Credential, View}
  alias SymphonyElixirWeb.{Endpoint, OperatorAuth, OperatorPanel}
  @endpoint Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "operator-web-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "token")
    :ok = Credential.create(path)
    auth = start_supervised!({Auth, settings: %{principal: "local:owner", credential_path: path, origin: "http://localhost"}})
    secret = File.read!(path) |> String.trim()
    {:ok, session} = Auth.login(auth, secret)
    saved = Application.get_env(:symphony_elixir, Endpoint, [])

    config =
      Keyword.merge(saved,
        server: false,
        operator_enabled: true,
        operator_auth: auth,
        check_origin: ["http://localhost"],
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
        orchestrator: :missing_operator_orchestrator,
        snapshot_timeout_ms: 5
      )

    Application.put_env(:symphony_elixir, Endpoint, config)
    start_supervised!(Endpoint)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, saved)
      File.rm_rf!(root)
    end)

    %{auth: auth, session: session, root: root, secret: secret}
  end

  defp guest, do: %{build_conn() | host: "localhost"} |> put_private(:plug_skip_csrf_protection, false)

  defp conn(c), do: guest() |> Plug.Test.init_test_session(%{operator_session: c.session, live_socket_id: "operator:" <> c.session})

  test "unauthenticated HTTP cannot see dashboard or API; login never renders secrets", c do
    assert get(guest(), "/").status == 302
    assert get(guest(), "/api/v1/state").status == 401
    response = get(guest(), "/operator/login")
    assert response.status == 200
    assert response.resp_body =~ "Вход оператора"
    refute response.resp_body =~ c.secret
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get(conn(c), "/api/v1/state").status == 200
    assert Endpoint.config(:check_origin) != false
  end

  test "wrong host, origin, missing CSRF and placeholder endpoint secret fail closed", c do
    assert get(%{conn(c) | host: "attacker.invalid"}, "/api/v1/state").status == 403
    bad = conn(c) |> put_req_header("origin", "https://attacker.invalid") |> post("/api/v1/refresh")
    assert bad.status == 403
    missing = conn(c) |> post("/api/v1/refresh")
    assert missing.status == 403

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn(c) |> put_req_header("origin", "http://localhost") |> post("/api/v1/refresh")
    end

    config = Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :secret_key_base, String.duplicate("s", 64))
    Endpoint.config_change([{Endpoint, config}], [])
    assert get(conn(c), "/api/v1/state").status == 503
  end

  test "browser login renews session, CSRF is required and logout revokes access", c do
    login = get(guest(), "/operator/login")
    token = Floki.parse_document!(login.resp_body) |> Floki.find("input[name=_csrf_token]") |> Floki.attribute("value") |> hd()
    response = login |> recycle() |> put_req_header("origin", "http://localhost") |> post("/operator/login", %{"credential" => c.secret, "_csrf_token" => token})
    assert redirected_to(response) == "/"
    signed = get_session(response, :operator_session)
    assert signed != c.session
    assert {:ok, "local:owner"} = Auth.check(c.auth, signed)
    assert get_session(response, :live_socket_id) == "operator:" <> signed
    csrf = Plug.CSRFProtection.get_csrf_token()
    logout = response |> recycle() |> put_req_header("origin", "http://localhost") |> post("/operator/logout", %{"_csrf_token" => csrf})
    assert redirected_to(logout) == "/operator/login"
    assert {:error, :operator_login_required} = Auth.check(c.auth, signed)
  end

  test "failed login is rate limited and credential is filtered from Phoenix logs", c do
    login = get(guest(), "/operator/login")
    csrf = Floki.parse_document!(login.resp_body) |> Floki.find("input[name=_csrf_token]") |> Floki.attribute("value") |> hd()

    for _ <- 1..5 do
      response = login |> recycle() |> put_req_header("origin", "http://localhost") |> post("/operator/login", %{"credential" => "wrong-secret", "_csrf_token" => csrf})
      assert response.status == 401
      refute response.resp_body =~ "wrong-secret"
    end

    response = login |> recycle() |> put_req_header("origin", "http://localhost") |> post("/operator/login", %{"credential" => c.secret, "_csrf_token" => csrf})
    assert response.status == 429
    assert Phoenix.Logger.filter_values(%{"credential" => c.secret}) == %{"credential" => "[FILTERED]"}
  end

  test "connected dashboard requires live session and revoked sessions cannot use events", c do
    assert {:error, {:redirect, %{to: "/operator/login"}}} = live(guest(), "/")
    {:ok, view, html} = live(conn(c), "/")
    assert html =~ "Controller недоступен"
    assert render_click(view, "operator_refresh", %{}) =~ "Запрошена сверка"
    assert render_click(view, "operator_prepare", %{"action" => "merge"}) =~ "unknown_operator_action"
    assert render_click(view, "operator_close_form", %{}) =~ "Controller недоступен"
    assert render_change(view, "operator_preview", %{}) =~ "Controller недоступен"
    assert Auth.revoke(c.auth) == :ok
    assert {:error, :operator_login_required} = OperatorAuth.live_session(c.session)
    assert {:halt, _} = OperatorAuth.on_mount(:default, %{}, %{"operator_session" => c.session}, %Phoenix.LiveView.Socket{})
  end

  test "guard protects alternate endpoint settings and disabled or unavailable registry", c do
    assert OperatorAuth.init(:api) == :api
    assert {:ok, info} = Auth.info(c.auth)
    assert info == %{principal: "local:owner", origin: "http://localhost"}
    :sys.replace_state(c.auth, &%{&1 | settings: nil})
    assert get(conn(c), "/api/v1/state").status == 503
    assert {:error, :operator_auth_unavailable} = OperatorAuth.live_session(c.session)
    config = Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :operator_enabled, false)
    Endpoint.config_change([{Endpoint, config}], [])
    assert get(guest(), "/operator/login").status == 404
    Endpoint.config_change([{Endpoint, Keyword.put(config, :operator_enabled, true)}], [])
    stop_supervised!(Auth)
    assert get(guest(), "/operator/login").status == 503
    assert {:error, :operator_auth_unavailable} = OperatorAuth.live_session(c.session)
  end

  test "panel renders proof, budget, decisions and escape-safe operator comments" do
    state = G.initial()
    deployment = Map.merge(G.deployment("a"), %{"queue" => %{"state" => "active"}, "scheduler" => "configured"})
    obs = %{facts: %{"repo" => "ExampleOrg/app", "dev_sha" => G.sha(), "deployment" => deployment, "pr" => %{"number" => 7, "state" => "open"}}, observed_at: "2026-09-17T00:00:00Z"}
    args = %{"kind" => "pause", "actor" => "local:owner", "reason" => "<script>bad</script>", "data" => %{}}
    record = %{"id" => "id", "args" => args, "at_ms" => 1_789_603_200_000}

    status = %{
      # An authenticated projection must never include internal credentials or store contents.
      gate: %{state: state},
      observation: obs,
      observation_age_ms: 0,
      reason: nil,
      worker: nil,
      restart_required: false
    }

    model = View.project(Map.put(status, :decisions, [record]))

    form = %{
      id: "form",
      action: "validate",
      version: %{revision: 3},
      proof: G.proof(),
      observed_at: obs.observed_at,
      choices: ["item-R"],
      limits: state["cycle"]["budget"]["limits"],
      preview: nil
    }

    for action <- ["validate", "pause", "problem", "cancel", "review_resume", "recovery", "extend_budget"] do
      current = View.preview(%{form | action: action}, %{"initial_minutes" => "5", "fix_minutes" => "3", "fixes" => "1", "ci_attempts" => "1", "retries_per_sha" => "1"})
      html = render_component(&OperatorPanel.panel/1, model: model, form: current, error: "Ошибка", notice: "Сохранено", busy: true, demo: true)
      assert html =~ "Демонстрация"
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>bad"
      assert html =~ G.sha()
    end
  end

  test "credential setup task does not print or overwrite a secret", c do
    target = Path.join(c.root, "new-token")
    output = ExUnit.CaptureIO.capture_io(fn -> Setup.run(["--path", target]) end)
    refute output =~ String.trim(File.read!(target))
    assert_raise Mix.Error, fn -> Setup.run(["--path", target]) end
    assert_raise Mix.Error, fn -> Setup.run([]) end
  end

  test "operator form submits through actual runtime and durable gate", c do
    config = put_in(F.fixture().config.delivery.state_path, Path.join(c.root, "state.json")).config
    {:ok, settings} = Config.delivery_observer_settings(config)
    gate = start_supervised!({DeliveryGate, settings: settings.gate})
    tasks = start_supervised!(Task.Supervisor)

    facts = %{
      # No unrelated PR may be present when validating the initial baseline.
      "dev_sha" => G.sha(),
      "deployment" => G.deployment("a"),
      "project" => %{"items" => []},
      "open_pr_numbers" => []
    }

    observer = fn _, opts -> {:ok, Observation.new(settings, opts[:context], facts, ["manual_dev_validation_required"])} end
    options = [config: config, gate: gate, task_supervisor: tasks, observer: observer, poll_ms: 0]
    runtime = start_supervised!({DeliveryRuntime, options})
    runtime_ready(runtime)
    endpoint_config = Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :operator_runtime, runtime)
    Endpoint.config_change([{Endpoint, endpoint_config}], [])
    {:ok, view, _} = live(conn(c), "/")
    html = render_click(view, "operator_prepare", %{"action" => "validate"})
    id = html |> Floki.parse_document!() |> Floki.find("input[name=form_id]") |> Floki.attribute("value") |> hd()
    assert html =~ G.sha()
    render_change(view, "operator_preview", %{"form_id" => id, "reason" => "Saved draft", "criteria" => ["app"]})
    assert has_element?(view, "input[value=app][checked]")
    assert render(view) =~ "Saved draft"
    render_submit(view, "operator_submit", %{"form_id" => id, "reason" => "Checked all", "criteria" => ["app", "scenario", "services"]})
    assert render_async(view) =~ "Решение сохранено"
    assert DeliveryGate.status(gate).state["baseline"]["actor"] == "local:owner"
    runtime_ready(runtime)
    html = render_click(view, "operator_prepare", %{"action" => "pause"})
    id = html |> Floki.parse_document!() |> Floki.find("input[name=form_id]") |> Floki.attribute("value") |> hd()
    render_submit(view, "operator_submit", %{"form_id" => id, "reason" => "Maintenance", "actor" => "forged"})
    assert render_async(view) =~ "invalid_operator_payload"
    render_submit(view, "operator_submit", %{"form_id" => id, "reason" => "Maintenance"})
    assert render_async(view) =~ "Решение сохранено"
    assert DeliveryGate.status(gate).state["operator_pause"]["actor"] == "local:owner"
  end

  defp runtime_ready(runtime, attempts \\ 500)
  defp runtime_ready(_, 0), do: flunk("runtime observation not ready")

  defp runtime_ready(runtime, n) do
    state = DeliveryRuntime.status(runtime)

    if state.observation && state.observation.expected_version == state.gate.version,
      do: state,
      else:
        (
          Process.sleep(10)
          runtime_ready(runtime, n - 1)
        )
  end
end
