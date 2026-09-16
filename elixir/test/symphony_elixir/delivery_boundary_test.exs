defmodule SymphonyElixir.DeliveryBoundaryTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.{Archive, Client, Evidence, Ownership, Policy, Runs}

  setup do
    f = F.fixture()
    %{f: f, client: F.client(f, start_supervised!(F.Cache))}
  end

  test "streamed ZIP descriptors, CRC, symlinks, encryption and expansion limits" do
    raw = String.duplicate("bounded expansion ", 20_000)
    zip = F.zip(raw)
    assert {:ok, ^raw} = Archive.read(zip, digest(zip))

    for descriptor <- [:signed, :plain] do
      streamed = descriptor_zip(zip, descriptor)
      assert {:ok, ^raw} = Archive.read(streamed, digest(streamed))
    end

    invalid = descriptor_zip(zip, :invalid)
    assert {:error, _} = Archive.read(invalid, digest(invalid))
    invalid = replace(zip, 0, <<0::32>>)
    assert {:error, _} = Archive.read(invalid, digest(invalid))
    offset = central_offset(zip)

    for invalid <- [
          replace(zip, offset + 38, <<0o120777 <<< 16::little-32>>),
          replace(zip, offset + 8, <<1::little-16>>),
          zip |> replace(14, <<0::little-32>>) |> replace(offset + 16, <<0::little-32>>)
        ] do
      assert {:error, _} = Archive.read(invalid, digest(invalid))
    end

    for options <- [[], [compress: []]] do
      bomb = F.zip(String.duplicate("x", 2_097_153), options)
      offset = central_offset(bomb)
      forged = bomb |> replace(22, <<1::little-32>>) |> replace(offset + 24, <<1::little-32>>)
      assert {:error, _} = Archive.read(forged, digest(forged))
    end

    <<namesize::little-16, extrasize::little-16>> = binary_part(zip, 26, 4)
    broken_deflate = replace(zip, 30 + namesize + extrasize, <<255, 255, 255, 255>>)
    assert {:error, _} = Archive.read(broken_deflate, digest(broken_deflate))
  end

  test "optional evidence step absent from GitHub cannot be silently omitted", %{f: f} do
    jobs =
      Enum.map(f.jobs, fn job ->
        Map.update!(job, "steps", &Enum.reject(&1, fn step -> step["name"] == "refreeze_cron" end))
      end)

    assert {:error, :evidence_contradicts_github} = Evidence.verify(f.zip, f.artifact, f.run, jobs, f.policy, f.settings)
  end

  test "unavailable readers and invalid metadata do not mean an empty inventory", %{f: f, client: client} do
    for response <- [F.ok(%{}), {:ok, %{status: 404, headers: %{}, body: ""}}] do
      broken = http(client, fn _ -> response end)
      assert {:error, _} = Ownership.ref(broken)
      assert {:error, _} = Runs.inventory(broken, f.run["path"], F.repo())
      assert {:error, _} = Policy.load(broken)
      assert {:error, _} = Client.content(broken, f.settings.policy["contract_path"], F.sha())
      assert {:error, _} = Client.download(broken, 30)
    end

    assert is_map(Client.new(f.settings))

    for reply <- [{:error, :project_unavailable}, {:ok, %{"project" => %{}, "items" => []}}] do
      broken = %{client | opts: Keyword.put(client.opts, :project_reader, fn _, _ -> reply end)}
      assert {:error, _} = Ownership.project(broken, F.repo())
    end

    for value <- [nil, "invalid-time"] do
      f = %{f | deployment_runs: [Map.put(f.run, "updated_at", value)]}
      assert {:error, _} = Runs.inventory(http(client, &F.response(f, &1)), f.run["path"], F.repo())
    end

    f = %{f | deployment_runs: [Map.merge(f.run, %{"status" => "queued", "conclusion" => nil})]}
    assert {:ok, _} = Runs.inventory(http(client, &F.response(f, &1)), f.run["path"], F.repo())
  end

  test "saved run disappeared or advanced, failed compare and failed artifact reads stay blocked", %{f: f, client: client} do
    inventory = %{runs: [f.run]}
    assert {:error, :saved_run_not_reconciled} = Runs.verify_saved(client, [%{runs: []}], [%{"run_id" => 20}])
    changed = http(client, fn _ -> F.ok(Map.put(f.run, "run_attempt", 2)) end)
    assert {:error, :saved_run_not_reconciled} = Runs.verify_saved(changed, [inventory], [%{"run_id" => 20}])
    failure = {:ok, %{status: 404, body: "", headers: %{}}}
    assert {:error, _} = Runs.verify_saved(http(client, fn _ -> failure end), [inventory], [%{"run_id" => 20}])

    for suffix <- ["/jobs", "/artifacts", "/zip"] do
      broken =
        http(client, fn opts ->
          if String.ends_with?(opts[:url], suffix), do: failure, else: F.response(f, opts)
        end)

      assert {:error, _} = Runs.deployment(broken, inventory, f.policy, F.sha(), F.repo())
    end

    for artifact <- [Map.put(f.artifact, "expired", true), Map.put(f.artifact, "size_in_bytes", 1), Map.put(f.artifact, "expires_at", "2020-01-01T00:00:00Z")] do
      altered = %{f | artifact: artifact}
      altered_client = http(client, &F.response(altered, &1))
      assert {:error, _} = Runs.deployment(altered_client, inventory, f.policy, F.sha(), F.repo())
    end

    missing =
      http(client, fn opts ->
        if String.ends_with?(opts[:url], "/artifacts"), do: F.page("artifacts", [], opts), else: F.response(f, opts)
      end)

    assert {:error, _} = Runs.deployment(missing, inventory, f.policy, F.sha(), F.repo())

    for changes <- [%{"event" => "pull_request"}, %{"head_repository" => %{"id" => 2}}] do
      assert {:error, _} = Runs.deployment(client, %{runs: [Map.merge(f.run, changes)]}, f.policy, F.sha(), F.repo())
    end
  end

  test "merge read failures and ambiguous CI reservation are explicit", %{f: f, client: client} do
    context = %{version: %{epoch: "one", revision: 1}, mode: :reconciled, state: G.reviewed()}
    f = Map.put(f, :pr, Map.merge(F.pr(), %{"merged" => true, "state" => "closed"}))

    broken =
      http(client, fn opts ->
        if String.contains?(opts[:url], "/compare/") do
          {:ok, %{status: 404, body: "", headers: %{}}}
        else
          F.response(f, opts)
        end
      end)

    assert {:error, _} = Ownership.observe(broken, context, %{"items" => []}, [], F.repo(), F.sha())
    f = put_in(f.pr["merge_commit_sha"], "bad")
    changed = http(client, &F.response(f, &1))
    assert {:error, :merge_sha_unconfirmed} = Ownership.observe(changed, context, %{"items" => []}, [], F.repo(), F.sha())
    {:ok, facts, _} = Ownership.observe(client, context, %{"items" => [F.item()]}, [], F.repo(), F.sha())
    inventory = %{workflow: F.workflow(11, ".github/workflows/pr-ci.yml"), runs: [F.ci_run()]}
    cycle = put_in(G.reviewed()["cycle"], ["budget", "ci", "ci-1", "sha"], F.sha("d"))
    assert {:error, :ambiguous_ci_reservation} = Runs.ci(client, inventory, f.policy, facts["pr"], cycle, F.sha())

    broken =
      http(client, fn opts ->
        if String.contains?(opts[:url], "/git/commits/") do
          {:ok, %{status: 404, body: "", headers: %{}}}
        else
          F.response(f, opts)
        end
      end)

    assert {:error, _} = Runs.ci(broken, inventory, f.policy, facts["pr"], cycle, F.sha())

    unknown_jobs =
      http(client, fn opts ->
        if String.ends_with?(opts[:url], "/jobs") do
          jobs = F.api_jobs(F.ci_run(), f.policy.pr_jobs) |> Enum.map(&Map.put(&1, "conclusion", "neutral"))
          F.page("jobs", jobs, opts)
        else
          F.response(f, opts)
        end
      end)

    assert {:ok, %{"result" => "unknown"}, _} = Runs.ci(unknown_jobs, inventory, f.policy, facts["pr"], nil, F.sha())
  end

  test "policy rejects non-list steps in an otherwise approved source", %{f: f} do
    path = f.settings.policy["deployment_workflow"]
    workflow = Jason.decode!(f.sources[path]) |> put_in(["jobs", "queue_pause", "steps"], [%{"name" => nil}])
    assert {:error, _} = Policy.parse(Map.put(f.sources, path, Jason.encode!(workflow)), f.settings)
    path = f.settings.policy["contract_path"]
    spec = put_in(f.policy.spec, ["jobs", "verify", "required_steps"], nil) |> Jason.encode!()
    settings = put_in(f.settings, [:policy, "contract_sha256"], Policy.hash(spec))
    assert {:error, _} = Policy.parse(Map.put(f.sources, path, spec), settings)
    jobs = Enum.map(f.jobs, &Map.put(&1, "name", "wrong"))
    assert {:error, :jobs_not_bound} = Evidence.bind_jobs(jobs, f.run, f.policy.jobs)
  end

  defp http(client, callback), do: %{client | opts: Keyword.put(client.opts, :http, callback)}
  defp digest(zip), do: "sha256:" <> Policy.hash(zip)

  defp central_offset(zip) do
    <<offset::little-32>> = binary_part(zip, byte_size(zip) - 6, 4)
    offset
  end

  defp replace(bytes, offset, replacement) do
    binary_part(bytes, 0, offset) <>
      replacement <>
      binary_part(bytes, offset + byte_size(replacement), byte_size(bytes) - offset - byte_size(replacement))
  end

  defp descriptor_zip(zip, kind) do
    offset = central_offset(zip)
    local = binary_part(zip, 0, offset) |> replace(6, <<8::little-16>>)
    central = binary_part(zip, offset, byte_size(zip) - offset - 22) |> replace(8, <<8::little-16>>)
    sizes = binary_part(local, 14, 12)

    descriptor =
      case kind do
        :signed -> <<0x08074B50::little-32>> <> sizes
        :plain -> sizes
        :invalid -> "bad"
      end

    tail = binary_part(zip, byte_size(zip) - 22, 22) |> replace(16, <<offset + byte_size(descriptor)::little-32>>)
    local <> descriptor <> central <> tail
  end
end
