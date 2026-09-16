defmodule SymphonyElixir.DeliveryObserverSupport do
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubProjects.Delivery.{Client, Policy, Settings}

  def sha(letter \\ "a"), do: String.duplicate(letter, 40)
  def repo, do: %{"id" => 1, "node_id" => "repo-node", "full_name" => "ExampleOrg/app"}

  def raw_config do
    %{
      "tracker" => %{
        "kind" => "github_projects",
        "active_states" => ["Ready for agent", "Agent working"],
        "terminal_states" => ["Done"],
        "provider" => %{
          "organization" => "ExampleOrg",
          "project_number" => 1,
          "repo" => "ExampleOrg/app",
          "github_app" => %{"app_id" => "123", "installation_id" => "456", "private_key_path" => "/controller/private.pem"}
        }
      },
      "workspace" => %{"root" => "/worker/workspaces"},
      "delivery" => %{
        "state_path" => "/controller/delivery.json",
        "observer" => %{
          "contract_commit" => sha(),
          "contract_sha256" => String.duplicate("a", 64)
        }
      }
    }
  end

  def fixture do
    raw = raw_config()
    {:ok, config} = Schema.parse(raw)
    {:ok, settings} = Settings.parse(config)
    names = ~w(verify scheduler_freeze queue_pause postgres_migrate cloudflare_deploy container_deploy
      score_container_deploy result_container_deploy scheduler_finalize queue_finalize)

    contracts =
      Map.new(names, fn name ->
        required = if name in ~w(scheduler_finalize queue_finalize), do: ~w(checkout admission), else: ~w(checkout complete)

        observed =
          case name do
            "scheduler_finalize" -> required ++ ~w(verify_restored_cron refreeze_cron)
            "queue_finalize" -> required ++ ~w(resume_queue pause_queue)
            _ -> required
          end

        {name, %{"kind" => if(String.ends_with?(name, "finalize"), do: "finalizer", else: "normal"), "dependencies" => [], "required_steps" => required, "observed_steps" => observed}}
      end)

    spec = %{"schema_version" => 1, "repository" => settings.repo, "workflow" => settings.policy["deployment_workflow"], "jobs" => contracts}

    jobs =
      Map.new(contracts, fn {name, contract} ->
        {name, %{"name" => name, "environment" => "development", "steps" => Enum.map(contract["observed_steps"], &%{"id" => &1, "name" => &1})}}
      end)

    verify = %{"jobs" => %{"verify" => %{jobs["verify"] | "name" => "Verify application"}}}
    jobs = Map.put(jobs, "verify", %{"name" => "Verify release", "uses" => "./" <> settings.policy["verify_workflow"]})

    jobs =
      Map.put(jobs, "deployment_evidence", %{
        "name" => "Development evidence",
        "steps" => [
          %{"id" => "collect", "name" => "Collect"},
          %{"id" => "publish", "name" => "Publish"},
          %{"name" => "Require evidence"}
        ]
      })

    pr = %{"jobs" => %{"verify" => %{"uses" => "./" <> settings.policy["verify_workflow"]}, "result" => %{"name" => "PR verification", "steps" => [%{"name" => "Require verification"}]}}}
    p = settings.policy

    sources = %{
      p["contract_path"] => Jason.encode!(spec),
      p["deployment_workflow"] => Jason.encode!(%{"jobs" => jobs}),
      p["verify_workflow"] => Jason.encode!(verify),
      p["pr_workflow"] => Jason.encode!(pr),
      p["producer_path"] => "# Approved synthetic fixture producer\n",
      p["ci_gate_path"] => "# Synthetic fixture CI gate\n"
    }

    raw = put_in(raw, ["delivery", "observer", "contract_sha256"], Policy.hash(sources[p["contract_path"]]))
    {:ok, config} = Schema.parse(raw)
    {:ok, settings} = Settings.parse(config)
    {:ok, policy} = Policy.parse(sources, settings)
    run = run()

    receipts =
      Map.new(contracts, fn {name, contract} ->
        steps = Map.new(contract["observed_steps"], &receipt_step/1)

        {name,
         Map.merge(identity(run), %{"schema_version" => 1, "job" => name, "checkout_sha" => sha(), "admitted" => true, "success" => true, "steps" => steps, "facts" => facts(name), "errors" => []})}
      end)

    report =
      Map.merge(identity(run), %{
        "schema_version" => 1,
        "workflow" => p["deployment_workflow"],
        "observed_at" => "2026-09-16T10:04:00Z",
        "current_dev_sha" => sha(),
        "freshness" => "current",
        "deployment" => "success",
        "manual_validation" => "pending",
        "next_task_allowed" => false,
        "environment" => %{"status" => "ready", "blockers" => [], "scheduler" => "configured", "queue" => facts("queue_finalize")},
        "jobs" => receipts,
        "errors" => []
      })

    zip = zip(Jason.encode!(report))
    artifact = artifact(zip)
    jobs = api_jobs(run, policy.jobs)

    jobs =
      Enum.map(jobs, fn job ->
        Map.update!(job, "steps", fn steps ->
          Enum.map(steps, &optional_step/1)
        end)
      end)

    %{
      raw: raw,
      config: config,
      settings: settings,
      sources: sources,
      policy: policy,
      run: run,
      report: report,
      zip: zip,
      artifact: artifact,
      jobs: jobs,
      project: project(),
      prs: [],
      ci_runs: [],
      deployment_runs: [run]
    }
  end

  defp optional_step(step) do
    if step["name"] in ~w(refreeze_cron pause_queue), do: Map.put(step, "conclusion", "skipped"), else: step
  end

  defp receipt_step(id) do
    outcome = if id in ~w(refreeze_cron pause_queue), do: "skipped", else: "success"
    {id, %{"outcome" => outcome, "conclusion" => outcome}}
  end

  def run do
    %{
      "id" => 20,
      "workflow_id" => 10,
      "path" => ".github/workflows/deploy-development.yml",
      "head_sha" => sha(),
      "head_branch" => "dev",
      "event" => "push",
      "run_attempt" => 1,
      "status" => "completed",
      "conclusion" => "success",
      "repository" => repo(),
      "head_repository" => repo(),
      "pull_requests" => [],
      "created_at" => "2026-09-16T10:00:00Z",
      "run_started_at" => "2026-09-16T10:00:00Z",
      "updated_at" => "2026-09-16T10:05:00Z"
    }
  end

  def identity(run) do
    %{
      "repository" => "ExampleOrg/app",
      "workflow_ref" => "ExampleOrg/app/.github/workflows/deploy-development.yml@refs/heads/dev",
      "ref" => "refs/heads/dev",
      "event" => run["event"],
      "sha" => run["head_sha"],
      "run_id" => to_string(run["id"]),
      "run_attempt" => to_string(run["run_attempt"])
    }
  end

  def facts("scheduler_freeze"), do: %{"freeze_started" => "true", "cron_disabled" => "true", "initial_cron_state" => "configured"}
  def facts("queue_pause"), do: %{"initial_state" => "active", "resume_required" => "true", "cutover_started" => "true", "guard_established" => "true"}
  def facts("scheduler_finalize"), do: %{"state" => "configured"}
  def facts("queue_finalize"), do: %{"state" => "active", "reason" => "resumed"}
  def facts(_), do: %{}

  def zip(raw, opts \\ []) do
    {:ok, {_, bytes}} = :zip.create(~c"evidence.zip", [{~c"development-evidence.json", raw}], [:memory | opts])
    bytes
  end

  def artifact(zip),
    do: %{
      "id" => 30,
      "name" => "development-evidence-20-1",
      "expired" => false,
      "expires_at" => "2099-01-01T00:00:00Z",
      "size_in_bytes" => byte_size(zip),
      "digest" => "sha256:" <> Policy.hash(zip),
      "workflow_run" => %{"id" => 20, "head_sha" => sha(), "head_branch" => "dev", "repository_id" => 1, "head_repository_id" => 1}
    }

  def repack(f), do: repack(f, f.report)

  def repack(f, report) do
    zip = zip(Jason.encode!(report))
    %{f | report: report, zip: zip, artifact: artifact(zip)}
  end

  def on_dev(f, letter) do
    sha = sha(letter)
    receipts = Map.new(f.report["jobs"], fn {name, job} -> {name, Map.merge(job, %{"sha" => sha, "checkout_sha" => sha})} end)
    report = Map.merge(f.report, %{"sha" => sha, "current_dev_sha" => sha, "jobs" => receipts})
    f = repack(f, report)
    run = Map.put(f.run, "head_sha", sha)
    %{f | run: run, deployment_runs: [run], jobs: Enum.map(f.jobs, &Map.put(&1, "head_sha", sha)), artifact: put_in(f.artifact, ["workflow_run", "head_sha"], sha)} |> Map.put(:dev_sha, sha)
  end

  def api_jobs(run, mapping) do
    mapping
    |> Enum.with_index(1)
    |> Enum.map(fn {{_key, value}, id} ->
      %{
        "id" => id,
        "run_id" => run["id"],
        "run_attempt" => run["run_attempt"],
        "head_sha" => run["head_sha"],
        "name" => value.name,
        "status" => "completed",
        "conclusion" => "success",
        "steps" => value.steps |> Map.values() |> Enum.map(&%{"name" => &1, "status" => "completed", "conclusion" => "success"})
      }
    end)
  end

  def project, do: %{"project" => %{"id" => "project-node", "repository_id" => "repo-node"}, "items" => []}

  def item(id \\ "item-A", issue \\ "issue-A"),
    do: %{"item_id" => id, "state" => "Agent working", "archived" => false, "issue_state" => "OPEN", "native_ref" => %{"issue_id" => issue, "repo" => "ExampleOrg/app"}, "reasons" => []}

  def pr do
    %{
      "id" => 7,
      "number" => 7,
      "state" => "open",
      "draft" => false,
      "merged" => false,
      "head" => %{"ref" => "agent/task-a", "sha" => sha("b"), "repo" => repo()},
      "base" => %{"ref" => "dev", "sha" => sha(), "repo" => repo()},
      "merge_commit_sha" => sha("c"),
      "updated_at" => "2026-09-16T10:05:00Z"
    }
  end

  def ci_run do
    Map.merge(run(), %{
      "id" => 100,
      "workflow_id" => 11,
      "path" => ".github/workflows/pr-ci.yml",
      "event" => "pull_request",
      "head_branch" => "agent/task-a",
      "head_sha" => sha("b"),
      "pull_requests" => [%{"id" => 7, "number" => 7}],
      "referenced_workflows" => [%{"ref" => "refs/pull/7/merge", "sha" => sha("c"), "path" => "ExampleOrg/app/.github/workflows/verify.yml@" <> sha("c")}]
    })
  end

  def opts(f, cache) do
    [
      credentials_cache: cache,
      http: fn opts -> response(f, opts) end,
      project_reader: fn tracker, _ ->
        if Map.has_key?(tracker.provider, "item_ids"), do: raise("pilot filter leaked into inventory")
        {:ok, f.project}
      end
    ]
  end

  def client(f, cache), do: Client.new(f.settings, opts(f, cache))

  def response(f, opts) do
    :get = opts[:method]
    false = opts[:redirect]
    uri = URI.parse(opts[:url])

    if uri.host == "productionresultsfixture.blob.core.windows.net" do
      [] = opts[:headers]
      ok(f.zip, false)
    else
      true = uri.host == "api.github.com"
      {"authorization", "Bearer fixture-token"} = List.keyfind(opts[:headers], "authorization", 0)
      path = String.replace_prefix(uri.path, "/repos/ExampleOrg/app", "")

      api_response(f, opts, path)
    end
  end

  defp api_response(_f, _opts, ""), do: ok(repo())
  defp api_response(f, _opts, "/git/ref/heads/dev"), do: ok(%{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => Map.get(f, :dev_sha, sha())}})
  defp api_response(f, _opts, "/pulls"), do: ok(f.prs)
  defp api_response(f, _opts, "/pulls/7"), do: ok(Map.get(f, :pr, pr()))
  defp api_response(_f, _opts, "/actions/workflows/deploy-development.yml"), do: ok(workflow(10, ".github/workflows/deploy-development.yml"))
  defp api_response(_f, _opts, "/actions/workflows/pr-ci.yml"), do: ok(workflow(11, ".github/workflows/pr-ci.yml"))
  defp api_response(f, opts, "/actions/workflows/10/runs"), do: page("workflow_runs", f.deployment_runs, opts)
  defp api_response(f, opts, "/actions/workflows/11/runs"), do: page("workflow_runs", f.ci_runs, opts)
  defp api_response(f, opts, "/actions/runs/20/attempts/1/jobs"), do: page("jobs", f.jobs, opts)
  defp api_response(f, opts, "/actions/runs/100/attempts/1/jobs"), do: page("jobs", api_jobs(ci_run(), f.policy.pr_jobs), opts)
  defp api_response(f, opts, "/actions/runs/20/artifacts"), do: page("artifacts", [f.artifact], opts)

  defp api_response(_f, _opts, "/actions/artifacts/30/zip"),
    do: {:ok, %{status: 302, body: "", headers: %{"location" => ["https://productionresultsfixture.blob.core.windows.net/archive?signature=private"]}}}

  defp api_response(f, _opts, "/actions/runs/20"), do: ok(f.run)
  defp api_response(f, _opts, "/actions/runs/100"), do: ok(Enum.find(f.ci_runs, &(&1["id"] == 100)))
  defp api_response(_f, _opts, "/git/commits/" <> sha), do: ok(%{"sha" => sha, "parents" => [%{"sha" => sha()}, %{"sha" => sha("b")}]})
  defp api_response(_f, _opts, "/compare/" <> _), do: ok(%{"status" => "ahead", "base_commit" => %{"sha" => sha("c")}, "merge_base_commit" => %{"sha" => sha("c")}})
  defp api_response(f, _opts, "/contents/" <> path), do: ok(%{"type" => "file", "path" => path, "encoding" => "base64", "content" => Base.encode64(f.sources[path])})

  def ok(body, encode \\ true), do: {:ok, %{status: 200, body: if(encode, do: Jason.encode!(body), else: body), headers: %{}}}

  def page(key, entries, opts) do
    page = opts[:params][:page] || 1
    ok(%{"total_count" => length(entries), key => Enum.slice(entries, (page - 1) * 100, 100)})
  end

  def workflow(id, path), do: %{"id" => id, "path" => path, "state" => "active"}
end

defmodule SymphonyElixir.DeliveryObserverSupport.Cache do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, [])
  def init(_), do: {:ok, nil}
  def handle_call({:token, _}, _, state), do: {:reply, {:ok, "fixture-token"}, state}
  def handle_call({:invalidate, _, _}, _, state), do: {:reply, :ok, state}
end
