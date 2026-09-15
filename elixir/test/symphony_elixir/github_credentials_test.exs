defmodule SymphonyElixir.GitHubCredentialsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias SymphonyElixir.GitHub.Credentials
  alias SymphonyElixir.GitHub.Credentials.{Cache, Issuer}

  @now 1_789_450_000

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    {:ok, key: key, pem: pem}
  end

  setup %{pem: pem} do
    root = Path.join(System.tmp_dir!(), "symphony-app-credentials-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "app.pem")
    File.write!(path, pem)
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, reference} = Credentials.reference(provider(path), :projects_read)
    {:ok, reference: reference, key_path: path, root: root}
  end

  test "reference freezes scoped identity, uses explicit profiles and hides key path", %{key_path: path} do
    provider = provider(path)
    {:ok, reference} = Credentials.reference(provider, :projects_read)
    assert reference.app_id == "123"
    assert reference.installation_id == "456"
    assert reference.repo == "example-org/app"
    assert reference.private_key_path == path
    assert reference.permissions == %{"organization_projects" => "read", "issues" => "read", "contents" => "read", "metadata" => "read"}
    refute inspect(reference) =~ path
    refute inspect(reference) =~ "private_key_path"

    {:ok, github} = Credentials.reference(Map.drop(provider, ["organization", "project_number"]), :github)
    assert github.permissions == %{"issues" => "write", "pull_requests" => "write", "contents" => "read", "metadata" => "read"}
    assert github.organization == nil

    {:ok, push} = Credentials.reference(provider, :contents_write)
    assert push.permissions == %{"contents" => "write", "metadata" => "read"}
    refute Map.has_key?(push.permissions, "organization_projects")
    refute Map.has_key?(push.permissions, "issues")
    refute Map.has_key?(push.permissions, "pull_requests")
    assert Credentials.reference(Map.put(provider, "token", nil), :projects_read) == {:error, :mixed_github_credentials}
  end

  test "configuration errors are bounded and cannot select another endpoint", %{key_path: path} do
    for {key, value} <- [
          {"app_id", nil},
          {"app_id", "not numeric"},
          {"app_id", 0},
          {"installation_id", nil},
          {"installation_id", "0"},
          {"private_key_path", "relative.pem"},
          {"private_key_path", nil},
          {"private_key_path", "/tmp/a" <> <<0>>},
          {"client_id", ""},
          {"client_id", nil},
          {"client_id", 42}
        ] do
      assert {:error, reason} =
               Credentials.reference(put_in(provider(path), ["github_app", key], value), :projects_read)

      assert is_atom(reason)
    end

    for {key, value} <- [
          {"github_app", nil},
          {"api_url", "https://attacker.invalid"},
          {"repo", nil},
          {"repo", "example-org/."},
          {"repo", "example-org/.."},
          {"repo", "bad"},
          {"organization", nil},
          {"organization", "other-owner"},
          {"organization", 123},
          {"project_number", nil},
          {"project_number", 0}
        ] do
      assert {:error, _reason} = Credentials.reference(Map.put(provider(path), key, value), :projects_read)
    end

    assert {:error, :invalid_github_credential_profile} = Credentials.reference(provider(path), :unknown)
    assert {:error, :invalid_github_app_config} = Credentials.reference(nil, :github)
  end

  test "unresolved environment references do not fall back and custom names are protected", %{key_path: path} do
    provider = put_in(provider(path), ["github_app", "app_id"], "$SYMPHONY_CREDENTIAL_TEST_ABSENT")
    assert {:error, :invalid_github_app_id} = Credentials.reference(provider, :projects_read)
    assert "SYMPHONY_CREDENTIAL_TEST_ABSENT" in Credentials.secret_environment_names(provider)

    provider = put_in(provider, ["github_app", "app_id"], "$INVALID-NAME")
    assert {:error, :invalid_github_app_id} = Credentials.reference(provider, :projects_read)
    refute "INVALID-NAME" in Credentials.secret_environment_names(provider)

    standard = Credentials.secret_environment_names(%{"github_app" => nil})
    assert standard == ["SYMPHONY_GITHUB_APP_ID", "SYMPHONY_GITHUB_APP_CLIENT_ID", "SYMPHONY_GITHUB_INSTALLATION_ID", "SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"]
  end

  test "issuer signs RS256 JWT and verifies installation before scoped mint", %{reference: reference, key: key} do
    parent = self()
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    token = "opaque." <> String.duplicate("long-unparsed-token", 40)

    request = fn method, path, body, jwt ->
      [header, payload, signature] = String.split(jwt, ".")
      assert decode(header) == %{"alg" => "RS256", "typ" => "JWT"}
      assert decode(payload) == %{"iat" => @now - 60, "exp" => @now + 540, "iss" => "123"}
      assert :public_key.verify(header <> "." <> payload, :sha256, Base.url_decode64!(signature, padding: false), public)
      send(parent, {:auth_request, method, path, body})
      exchange(reference, token).(method, path, body, jwt)
    end

    assert {:ok, ^token, expiry} = Issuer.issue(reference, @now, request_fun: request)
    assert expiry == @now + 3_600
    assert_received {:auth_request, "GET", "/app/installations/456", nil}
    assert_received {:auth_request, "POST", "/app/installations/456/access_tokens", body}
    assert body == %{"repositories" => ["app"], "permissions" => reference.permissions}
  end

  test "client ID is preferred as JWT issuer", %{key_path: path} do
    {:ok, reference} = Credentials.reference(put_in(provider(path), ["github_app", "client_id"], "Iv1.fixture"), :projects_read)

    request = fn method, path, body, jwt ->
      assert jwt |> String.split(".") |> Enum.at(1) |> decode() |> Map.fetch!("iss") == "Iv1.fixture"
      exchange(reference).(method, path, body, jwt)
    end

    assert {:ok, _token, _expires} = Issuer.issue(reference, @now, request_fun: request)
  end

  test "installation identity mismatch or suspension prevents mint", %{reference: reference} do
    for replacement <- [
          %{"app_id" => 999},
          %{"id" => 999},
          %{"account" => %{"login" => "other-org", "type" => "Organization"}},
          %{"account" => %{"login" => "example-org", "type" => "User"}},
          %{"account" => nil},
          %{"suspended_at" => "2026-09-15T00:00:00Z"}
        ] do
      request = fn method, _path, _body, _jwt ->
        assert method == "GET"
        {:ok, %{status: 200, body: Map.merge(installation(), replacement)}}
      end

      assert {:error, reason} = Issuer.issue(reference, @now, request_fun: request)
      assert reason in [:github_installation_identity_mismatch, :github_installation_suspended]
    end
  end

  test "returned tokens must match exact repository and permissions", %{reference: reference} do
    for replacement <- [
          %{"token" => ""},
          %{"token" => nil},
          %{"permissions" => Map.put(reference.permissions, "actions", "write")},
          %{"permissions" => Map.delete(reference.permissions, "issues")},
          %{"repository_selection" => "all"},
          %{"repositories" => []},
          %{"repositories" => [%{"id" => 10, "full_name" => "other-org/app"}]},
          %{"repositories" => [%{"id" => 10, "full_name" => "example-org/app"}, %{"id" => 11, "full_name" => "example-org/other"}]},
          %{"repositories" => [%{"id" => 0, "full_name" => "example-org/app"}]},
          %{"expires_at" => timestamp(@now + 60)},
          %{"expires_at" => timestamp(@now + 3_661)},
          %{"expires_at" => "invalid"}
        ] do
      request = exchange(reference, "fixture-token", replacement)
      assert {:error, :github_installation_token_invalid} = Issuer.issue(reference, @now, request_fun: request)
    end
  end

  test "private key must be a protected regular RSA file", %{reference: reference, key_path: path, key: key} do
    File.chmod!(path, 0o644)
    assert {:error, :github_app_key_unavailable} = Issuer.issue(reference, @now, [])
    File.chmod!(path, 0o600)

    link = path <> ".link"
    File.ln_s!(path, link)
    assert {:error, :github_app_key_unavailable} = Issuer.issue(%{reference | private_key_path: link}, @now, [])
    assert {:error, :github_app_key_unavailable} = Issuer.issue(%{reference | private_key_path: path <> ".missing"}, @now, [])

    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    weak = :public_key.generate_key({:rsa, 1024, 65_537})
    below_minimum = :public_key.generate_key({:rsa, 2047, 65_537})
    no_http = fn _, _, _, _ -> {:error, :invalid_key_reached_http} end

    for pem <- [
          "not a pem",
          "-----BEGIN RSA PRIVATE KEY-----\nYQ==\n-----END RSA PRIVATE KEY-----\n",
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public)]),
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, weak)]),
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, below_minimum)])
        ] do
      File.write!(path, pem)
      assert {:error, :github_app_key_invalid} = Issuer.issue(reference, @now, request_fun: no_http)
    end
  end

  test "transport and unexpected failures return no raw body, JWT, or exception", %{reference: reference} do
    canary = "DO_NOT_LOG_CREDENTIAL_CANARY"

    for request <- [
          fn _, _, _, _ -> {:error, canary} end,
          fn _, _, _, _ -> :unexpected end,
          fn _, _, _, _ -> raise canary end,
          fn _, _, _, _ -> throw(canary) end,
          fn _, _, _, _ -> {:ok, %{status: 403, body: canary}} end
        ] do
      log =
        capture_log(fn ->
          assert {:error, reason} = Issuer.issue(reference, @now, request_fun: request)
          refute inspect(reason) =~ canary
        end)

      refute log =~ canary
    end
  end

  test "actual Req pipeline forbids redirects and retries and keeps JWT on api.github.com", %{reference: reference} do
    request = fn request ->
      assert request.url.host == "api.github.com"
      assert request.url.scheme == "https"
      assert request.options[:redirect] == false
      assert request.options[:retry] == false
      ["Bearer " <> jwt] = Req.Request.get_header(request, "authorization")
      assert jwt |> String.split(".") |> length() == 3
      method = if request.method == :get, do: "GET", else: "POST"
      body = if request.method == :post, do: Jason.decode!(request.body), else: nil
      {:ok, response} = exchange(reference).(method, request.url.path, body, jwt)
      {request, Req.Response.new(status: response.status, body: response.body)}
    end

    assert {:ok, "fixture-token", _expiry} = Issuer.issue(reference, @now, req_adapter: request)

    redirect = fn request ->
      send(self(), :redirect_attempt)
      {request, Req.Response.new(status: 302, headers: [{"location", "https://attacker.invalid"}], body: "")}
    end

    assert {:error, {:github_credential_http, 302}} = Issuer.issue(reference, @now, req_adapter: redirect)
    assert_received :redirect_attempt
    refute_received :redirect_attempt

    broken = fn request -> {request, %Req.TransportError{reason: :econnrefused}} end
    assert {:error, :github_credential_request_failed} = Issuer.issue(reference, @now, req_adapter: broken)
  end

  test "concurrent callers share one refresh and cache tokens until the renewal margin", %{reference: reference} do
    clock = clock()
    count = :atomics.new(1, [])
    parent = self()

    request = fn method, path, body, jwt ->
      if method == "POST", do: :atomics.add(count, 1, 1)
      send(parent, {:request_method, method})
      replacement = %{"expires_at" => timestamp(:atomics.get(clock, 1) + 3_600)}
      exchange(reference, "fixture-token", replacement).(method, path, body, jwt)
    end

    cache = start_supervised!({Cache, name: nil, request_fun: request, now_fun: fn -> :atomics.get(clock, 1) end})
    tasks = Enum.map(1..12, fn _ -> Task.async(fn -> Credentials.token(reference, credentials_cache: cache) end) end)
    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate({:ok, "fixture-token"}, 12)
    assert :atomics.get(count, 1) == 1

    :atomics.put(clock, 1, @now + 3_539)
    assert {:ok, "fixture-token"} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(count, 1) == 1
    :atomics.put(clock, 1, @now + 3_540)
    assert {:ok, "fixture-token"} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(count, 1) == 2
    :atomics.put(clock, 1, @now + 7_200)
    assert {:ok, "fixture-token"} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(count, 1) == 3
  end

  test "refresh errors replace expired credentials and backoff starts after request completion", %{reference: reference} do
    clock = clock()
    count = :atomics.new(1, [])

    request = fn _method, _path, _body, _jwt ->
      :atomics.add(count, 1, 1)
      :atomics.put(clock, 1, @now + 10)
      {:error, :timeout}
    end

    cache = start_supervised!({Cache, name: nil, request_fun: request, now_fun: fn -> :atomics.get(clock, 1) end})
    assert {:error, :github_credential_request_failed} = Credentials.token(reference, credentials_cache: cache)
    assert {:error, :github_credential_request_failed} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(count, 1) == 1
    :atomics.put(clock, 1, @now + 15)
    assert {:error, :github_credential_request_failed} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(count, 1) == 2
  end

  test "a token that becomes stale during exchange is not returned", %{reference: reference} do
    clock = clock()

    request = fn method, path, body, jwt ->
      if method == "POST", do: :atomics.put(clock, 1, @now + 3_550)
      exchange(reference).(method, path, body, jwt)
    end

    cache = start_supervised!({Cache, name: nil, request_fun: request, now_fun: fn -> :atomics.get(clock, 1) end})
    assert {:error, :github_installation_token_invalid} = Credentials.token(reference, credentials_cache: cache)
  end

  test "late unauthorized responses cannot evict a newer token and profiles stay separate", %{reference: reference} do
    counter = :atomics.new(1, [])

    request = fn method, path, body, jwt ->
      number = if method == "POST", do: :atomics.add_get(counter, 1, 1), else: :atomics.get(counter, 1)
      exchange(reference, "token-#{number}").(method, path, body, jwt)
    end

    cache = start_supervised!({Cache, name: nil, request_fun: request, now_fun: fn -> @now end})
    assert {:ok, "token-1"} = Credentials.token(reference, credentials_cache: cache)
    assert :ok = Credentials.invalidate(reference, "token-1", credentials_cache: cache)
    assert {:ok, "token-2"} = Credentials.token(reference, credentials_cache: cache)
    assert :ok = Credentials.invalidate(reference, "token-1", credentials_cache: cache)
    assert {:ok, "token-2"} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(counter, 1) == 2

    changed = %{reference | project_number: 2}
    assert {:ok, "token-3"} = Credentials.token(changed, credentials_cache: cache)
    assert :atomics.get(counter, 1) == 3
  end

  test "cache diagnostics and induced termination do not expose cached tokens or failing messages", %{reference: reference} do
    canary = "SECRET_CACHED_TOKEN_CANARY"
    cache = start_supervised!({Cache, name: nil, request_fun: exchange(reference, canary), now_fun: fn -> @now end})
    assert {:ok, ^canary} = Credentials.token(reference, credentials_cache: cache)
    refute inspect(:sys.get_state(cache)) =~ canary
    refute inspect(:sys.get_status(cache)) =~ canary
    refute inspect(:sys.get_status(cache)) =~ reference.private_key_path

    log =
      capture_log(fn ->
        assert {:error, :github_credential_request_invalid} = GenServer.call(cache, {:unsupported_message, canary})
        GenServer.cast(cache, {:unsupported_cast, canary})
        send(cache, {:unsupported_info, canary})
        assert {:ok, ^canary} = Credentials.token(reference, credentials_cache: cache)
        assert :ok = :sys.terminate(cache, {:induced_failure, canary})
      end)

    refute log =~ canary
    refute log =~ reference.private_key_path
  end

  test "cache restart loses credentials and unavailable cache fails closed", %{reference: reference} do
    request = exchange(reference)
    {:ok, cache} = Cache.start_link(name: nil, request_fun: request, now_fun: fn -> @now end)
    assert {:ok, "fixture-token"} = Credentials.token(reference, credentials_cache: cache)
    GenServer.stop(cache)
    assert {:error, :github_credentials_unavailable} = Credentials.token(reference, credentials_cache: cache)
    assert {:error, :github_credentials_unavailable} = Credentials.invalidate(reference, "fixture-token", credentials_cache: cache)

    cache = start_supervised!({Cache, name: nil, request_fun: request, now_fun: fn -> @now end})
    assert {:ok, "fixture-token"} = Credentials.token(reference, credentials_cache: cache)
  end

  test "unexpected clock failures clear cached credentials without leaking their value", %{reference: reference} do
    for failure <- [:raise, :throw] do
      flag = :atomics.new(1, [])

      clock = fn ->
        case {:atomics.get(flag, 1), failure} do
          {0, _failure} -> @now
          {1, :raise} -> raise "CLOCK_SECRET_CANARY"
          {1, :throw} -> throw("CLOCK_SECRET_CANARY")
        end
      end

      {:ok, cache} = Cache.start_link(name: nil, request_fun: exchange(reference, "CACHED_SECRET_CANARY"), now_fun: clock)
      assert {:ok, "CACHED_SECRET_CANARY"} = Credentials.token(reference, credentials_cache: cache)
      :atomics.put(flag, 1, 1)

      log =
        capture_log(fn ->
          assert {:error, :github_credentials_unavailable} = Credentials.token(reference, credentials_cache: cache)
        end)

      refute log =~ "SECRET_CANARY"
      assert :sys.get_state(cache).entries == %{}
      GenServer.stop(cache)
    end
  end

  defp provider(path) do
    %{
      "repo" => "example-org/app",
      "organization" => "example-org",
      "project_number" => 1,
      "github_app" => %{"app_id" => 123, "installation_id" => "456", "private_key_path" => path}
    }
  end

  defp exchange(reference, token \\ "fixture-token", replacement \\ %{}) do
    fn
      "GET", "/app/installations/456", nil, _jwt ->
        {:ok, %{status: 200, body: installation()}}

      "POST", "/app/installations/456/access_tokens", body, _jwt ->
        assert body["repositories"] == ["app"]
        assert body["permissions"] == reference.permissions
        {:ok, %{status: 201, body: Map.merge(token_response(reference, token), replacement)}}
    end
  end

  defp installation do
    %{"id" => 456, "app_id" => 123, "account" => %{"login" => "example-org", "type" => "Organization"}, "suspended_at" => nil}
  end

  defp token_response(reference, token) do
    %{
      "token" => token,
      "expires_at" => timestamp(@now + 3_600),
      "permissions" => reference.permissions,
      "repository_selection" => "selected",
      "repositories" => [%{"id" => 10, "full_name" => reference.repo}]
    }
  end

  defp clock do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, @now)
    clock
  end

  defp timestamp(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
  defp decode(value), do: value |> Base.url_decode64!(padding: false) |> Jason.decode!()
end

defmodule SymphonyElixir.GitHubCredentialsDefaultCacheTest do
  use ExUnit.Case

  alias SymphonyElixir.GitHub.Credentials
  alias SymphonyElixir.GitHub.Credentials.Cache

  test "default cache API fails safely when the configured key is missing" do
    provider = %{
      "repo" => "example-org/app",
      "github_app" => %{"app_id" => 123, "installation_id" => 456, "private_key_path" => "/not-present-symphony-test.pem"}
    }

    {:ok, reference} = Credentials.reference(provider, :github)

    case Cache.start_link() do
      {:ok, cache} ->
        assert {:error, :github_app_key_unavailable} = Credentials.token(reference)
        assert :ok = Credentials.invalidate(reference, "unknown")
        GenServer.stop(cache)

      {:error, {:already_started, _cache}} ->
        assert {:error, :github_app_key_unavailable} = Credentials.token(reference)
        assert :ok = Credentials.invalidate(reference, "unknown")
    end
  end
end
