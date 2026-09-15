defmodule SymphonyElixir.GitHubAppIntegrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.{Client, Credentials}
  alias SymphonyElixir.GitHub.Credentials.Cache
  alias SymphonyElixir.GitHubProjects.{Adapter, Inspection, Settings}
  alias SymphonyElixir.GitHubProjects.Client, as: ProjectsClient
  alias SymphonyElixir.Tracker

  @fixture Path.expand("../fixtures/github_projects/snapshot.json", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "symphony-app-integration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    key_path = Path.join(root, "fixture.pem")
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    File.write!(key_path, :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)]))
    File.chmod!(key_path, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, key_path: key_path}
  end

  test "App config validates without reading its key and rejects token fallback", context do
    tracker = tracker(context, :github)
    missing = put_in(tracker, [:provider, "github_app", "private_key_path"], "/nonexistent/controller/key.pem")
    assert :ok = Client.validate_settings(missing)
    assert :ok = Adapter.validate_config(tracker(context, :projects_read))

    with_env("GITHUB_TOKEN", "fallback-must-not-be-used", fn ->
      malformed = put_in(tracker, [:provider, "github_app", "app_id"], nil)
      assert {:error, :invalid_github_app_id} = Client.validate_settings(malformed)
      assert_raise ArgumentError, "Unable to bind tracker credentials", fn -> Tracker.bind_agent_tools(malformed) end

      assert {:error, :mixed_github_credentials} =
               Client.validate_settings(put_in(tracker, [:provider, "token"], "explicit-token"))

      assert {:error, :mixed_github_credentials} =
               ProjectsClient.validate_settings(put_in(tracker(context, :projects_read), [:provider, "token"], "explicit-token"))
    end)

    assert {:error, :invalid_github_app_api_url} =
             Client.validate_settings(put_in(tracker, [:provider, "api_url"], "https://elsewhere.example"))

    for token <- ["", "   ", "\t"] do
      assert {:error, :missing_github_token} = Client.validate_settings(legacy(token))
      project = tracker(context, :projects_read) |> update_in([:provider], &(&1 |> Map.delete("github_app") |> Map.put("token", token)))
      assert {:error, :missing_github_projects_token} = Settings.parse(project)
    end
  end

  test "bound App tools keep repo and App identity while tokens refresh", context do
    {cache, clock} = cache()
    env = "SYMPHONY_PR03_BIND_APP_ID"
    repo_env = "SYMPHONY_PR03_BIND_REPO"

    with_env(env, "123", fn ->
      with_env(repo_env, "ExampleOrg/app", fn ->
        tracker =
          tracker(context, :github)
          |> put_in([:provider, "github_app", "app_id"], "$" <> env)
          |> put_in([:provider, "repo"], "$" <> repo_env)

        binding = Tracker.bind_agent_tools(tracker)
        assert env in binding.secret_environment_names
        assert "SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH" in binding.secret_environment_names
        refute inspect(binding) =~ context.key_path

        System.put_env(env, "999")
        System.put_env(repo_env, "OtherOrg/other")

        request = fn "POST", "/repos/ExampleOrg/app/issues/1/comments", %{}, _, settings ->
          assert settings.repo == "ExampleOrg/app"
          assert settings.credential_reference.app_id == "123"
          {:ok, %{status: 201, body: %{"token_seen" => settings.token}}}
        end

        client = fn method, path, params, body, opts ->
          Client.request(method, path, params, body, Keyword.put(opts, :request_fun, request))
        end

        args = %{"method" => "POST", "path" => "/repos/ExampleOrg/app/issues/1/comments", "body" => %{"body" => "fixture"}}
        first = Tracker.execute_bound_agent_tool(binding, "github_api", args, github_client: client, credentials_cache: cache)
        assert first["success"]
        assert first["output"] =~ "installation-fixture-1"
        :atomics.add(clock, 1, 3_600)
        second = Tracker.execute_bound_agent_tool(binding, "github_api", args, github_client: client, credentials_cache: cache)
        assert second["success"]
        assert second["output"] =~ "installation-fixture-2"
        assert :atomics.get(clock, 2) == 2
      end)
    end)
  end

  test "legacy bound tools retain externally renewed token behavior" do
    env = "SYMPHONY_PR03_LEGACY_TOKEN"

    with_env(env, "first", fn ->
      binding = Tracker.bind_agent_tools(legacy("$" <> env))
      System.put_env(env, "second")

      assert {:ok, %{body: "second"}} =
               Client.request("GET", "/user", %{}, nil,
                 tracker_settings: binding.tracker_settings,
                 request_fun: fn _, _, _, _, settings -> {:ok, %{status: 200, body: settings.token}} end
               )
    end)
  end

  test "App requests reject repo escapes before token lookup", context do
    paths = [
      "/user",
      "/installation/token",
      "/app/installations/7/access_tokens",
      "/repos/OtherOrg/app/issues",
      "/repos/ExampleOrg/application/issues",
      "https://api.github.com/repos/ExampleOrg/app/issues",
      "//api.github.com/repos/ExampleOrg/app/issues",
      "/repos/ExampleOrg/app/../other",
      "/repos/ExampleOrg/app/../../other/repo",
      "/repos/ExampleOrg/app/%2e%2e/other",
      "/repos/ExampleOrg/app/issues%2f..",
      "/repos/ExampleOrg/app/%5c..",
      "/repos/ExampleOrg/app//issues",
      "/repos/ExampleOrg/app/issues?redirect=other",
      "/repos/ExampleOrg/app/issues#fragment"
    ]

    for path <- paths do
      assert {:error, :github_app_path_outside_scope} =
               Client.request("POST", path, %{}, %{},
                 tracker_settings: tracker(context, :github),
                 credentials_cache: :missing_fixture_cache,
                 request_fun: fn _, _, _, _, _ -> flunk("out-of-scope request reached transport") end
               )
    end
  end

  test "unauthorized mutation is sent once and invalidates only for the next request", context do
    {cache, clock} = cache()
    tracker = tracker(context, :github)
    calls = :atomics.new(1, [])

    request = fn "POST", _, _, _, _ ->
      :atomics.add(calls, 1, 1)
      {:ok, %{status: 401, body: %{"message" => "unauthorized"}}}
    end

    assert {:ok, %{status: 401}} =
             Client.request("POST", "/repos/ExampleOrg/app/issues/1/comments", %{}, %{}, tracker_settings: tracker, credentials_cache: cache, request_fun: request)

    assert :atomics.get(calls, 1) == 1
    assert :atomics.get(clock, 2) == 1
    assert {:ok, reference} = Credentials.reference(tracker.provider, :github)
    assert {:ok, "installation-fixture-2"} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(clock, 2) == 2
  end

  test "unavailable credentials and transport failures are safe and never fall back", context do
    {cache, _clock} = cache()
    tracker = tracker(context, :github)

    with_env("GITHUB_TOKEN", "never-fallback", fn ->
      assert {:error, :github_credentials_unavailable} =
               Client.request("GET", "/repos/ExampleOrg/app/issues", %{}, nil,
                 tracker_settings: tracker,
                 credentials_cache: :missing_fixture_cache,
                 request_fun: fn _, _, _, _, _ -> flunk("request without credentials") end
               )
    end)

    for request <- [
          fn _, _, _, _, _ -> {:error, %{token: "secret-raw-reason"}} end,
          fn _, _, _, _, _ -> raise "secret-raw-reason" end,
          fn _, _, _, _, _ -> throw("secret-raw-reason") end
        ] do
      opts = [tracker_settings: tracker, credentials_cache: cache, request_fun: request]
      assert {:error, :github_transport_error} = Client.request("POST", "/repos/ExampleOrg/app/issues", %{}, %{}, opts)
    end
  end

  test "Project pages fetch a fresh token under the same immutable reference", context do
    {cache, clock} = cache()
    fixture = @fixture |> File.read!() |> Jason.decode!()
    observed = :atomics.new(1, [])

    request = fn query, _vars, settings ->
      page = :atomics.add_get(observed, 1, 1)
      assert settings.credential_reference.installation_id == "7"

      if page == 1 do
        assert settings.token == "installation-fixture-1"
        :atomics.add(clock, 1, 3_600)
      else
        assert settings.token == "installation-fixture-2"
      end

      cond do
        query =~ "SymphonyProjectIdentity" -> ok(fixture["identity"])
        query =~ "SymphonyProjectFields" -> project_connection("fields", fixture["fields"])
        query =~ "SymphonyProjectItems" -> project_connection("items", fixture["items"])
      end
    end

    assert {:ok, report} =
             ProjectsClient.inspect(tracker(context, :projects_read), credentials_cache: cache, request_fun: request)

    assert report["summary"]["total"] == 1
    assert :atomics.get(observed, 1) == 3
    assert :atomics.get(clock, 2) == 2
    refute Jason.encode!(report) =~ "installation-fixture"
  end

  test "Project unauthorized reads invalidate once without replay", context do
    {cache, clock} = cache()
    tracker = tracker(context, :projects_read)
    calls = :atomics.new(1, [])

    request = fn _, _, _ ->
      :atomics.add(calls, 1, 1)
      {:ok, %{status: 401, body: %{}}}
    end

    assert {:error, {:github_projects_http, 401, nil}} =
             ProjectsClient.inspect(tracker, credentials_cache: cache, request_fun: request)

    assert :atomics.get(calls, 1) == 1
    assert {:ok, reference} = Credentials.reference(tracker.provider, :projects_read)
    assert {:ok, "installation-fixture-2"} = Credentials.token(reference, credentials_cache: cache)
    assert :atomics.get(clock, 2) == 2
  end

  test "finite App inspection owns an unregistered cache and always releases it", context do
    path = Path.join(context.root, "WORKFLOW.md")
    write_project_workflow(path, context)
    global_cache = Process.whereis(Cache)
    parent = self()

    for outcome <- [:ok, :error, :raise, :stopped] do
      reader = fn _tracker, opts ->
        cache = Keyword.fetch!(opts, :credentials_cache)
        assert Process.info(cache, :registered_name) == {:registered_name, []}
        send(parent, {:inspection_cache, cache})

        case outcome do
          :ok ->
            {:ok, %{"items" => []}}

          :error ->
            {:error, :fixture_failed}

          :raise ->
            raise "fixture failure"

          :stopped ->
            GenServer.stop(cache)
            {:error, :fixture_stopped}
        end
      end

      if outcome == :raise do
        assert_raise RuntimeError, "fixture failure", fn ->
          Inspection.run(path, inspect_project: reader)
        end
      else
        Inspection.run(path, inspect_project: reader)
      end

      assert_received {:inspection_cache, cache}
      refute Process.alive?(cache)
      assert Process.whereis(Cache) == global_cache
    end

    assert {:error, :github_credentials_unavailable} =
             Inspection.run(path,
               start_credentials_cache: fn _ -> {:error, {:cannot_start, "secret"}} end,
               inspect_project: fn _, _ -> flunk("reader must not start without cache") end
             )
  end

  defp tracker(context, profile) do
    provider = %{
      "repo" => "ExampleOrg/app",
      "github_app" => %{"app_id" => 123, "installation_id" => 7, "private_key_path" => context.key_path}
    }

    if profile == :projects_read do
      %{
        kind: "github_projects",
        provider: Map.merge(provider, %{"organization" => "ExampleOrg", "project_number" => 1, "context_fields" => ["Acceptance command"]}),
        active_states: ["Ready for agent", "Agent working"],
        terminal_states: ["Done"],
        required_labels: []
      }
    else
      %{kind: "github", provider: provider, active_states: ["open"], terminal_states: ["closed"]}
    end
  end

  defp legacy(token),
    do: %{kind: "github", provider: %{"repo" => "ExampleOrg/app", "token" => token}, active_states: ["open"], terminal_states: ["closed"]}

  defp cache do
    clock = :atomics.new(2, [])
    :atomics.put(clock, 1, 1_800_000_000)

    request = fn
      "GET", "/app/installations/7", nil, _jwt ->
        {:ok, %{status: 200, body: %{"app_id" => 123, "id" => 7, "account" => %{"login" => "ExampleOrg", "type" => "Organization"}}}}

      "POST", "/app/installations/7/access_tokens", body, _jwt ->
        serial = :atomics.add_get(clock, 2, 1)
        expires = :atomics.get(clock, 1) + 3_600
        assert body["repositories"] == ["app"]

        {:ok,
         %{
           status: 201,
           body: %{
             "token" => "installation-fixture-#{serial}",
             "expires_at" => DateTime.from_unix!(expires) |> DateTime.to_iso8601(),
             "permissions" => body["permissions"],
             "repository_selection" => "selected",
             "repositories" => [%{"id" => 11, "full_name" => "ExampleOrg/app"}]
           }
         }}
    end

    cache = start_supervised!({Cache, name: nil, now_fun: fn -> :atomics.get(clock, 1) end, request_fun: request})
    {cache, clock}
  end

  defp write_project_workflow(path, context) do
    File.write!(path, """
    ---
    tracker:
      kind: github_projects
      provider:
        organization: ExampleOrg
        project_number: 1
        repo: ExampleOrg/app
        github_app:
          app_id: 123
          installation_id: 7
          private_key_path: #{context.key_path}
      active_states: [Ready for agent, Agent working]
      terminal_states: [Done]
    ---
    """)
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
    end
  end

  defp project_connection(name, nodes),
    do: ok(%{"node" => %{"__typename" => "ProjectV2", "id" => "PVT_fixture", name => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}})

  defp ok(data), do: {:ok, %{status: 200, body: %{"data" => data}}}
end
