defmodule SymphonyElixir.DeliveryEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.{Archive, Evidence, JSON, Policy}

  setup do
    %{f: F.fixture(), cache: start_supervised!(F.Cache)}
  end

  test "full receipts and GitHub steps prove deployment, not human validation", %{f: f} do
    assert {:ok, result} = verify(f)
    assert result.complete and result.environment_ready
    assert result.deployment == "success"
    assert result.source == "deployment_evidence"
    assert result.observed_at == f.report["observed_at"]
  end

  test "inherited pause is a successful deployment with a separate readiness blocker", %{f: f} do
    queue = %{"state" => "paused", "reason" => "inherited_pause"}

    report =
      f.report
      |> put_in(["jobs", "queue_pause", "facts", "initial_state"], "paused")
      |> put_in(["jobs", "queue_pause", "facts", "resume_required"], "false")
      |> put_in(["jobs", "queue_finalize", "facts"], queue)
      |> put_in(["environment", "queue"], queue)
      |> put_in(["environment", "status"], "blocked")
      |> put_in(["environment", "blockers"], ["resume_queue_before_dev_validation"])

    assert {:ok, result} = verify(F.repack(f, report))
    assert result.complete
    assert result.deployment == "success"
    refute result.environment_ready
    assert result.blockers == ["resume_queue_before_dev_validation"]
  end

  test "stale deployment-time dev is never ready; unknown or contradictory freshness is rejected", %{f: f} do
    for {sha, freshness} <- [{F.sha("b"), "stale"}, {nil, "unknown"}] do
      report =
        f.report
        |> Map.merge(%{"current_dev_sha" => sha, "freshness" => freshness})
        |> put_in(["environment", "status"], "blocked")
        |> put_in(["environment", "blockers"], [if(freshness == "stale", do: "stale_dev_commit", else: "dev_head_unavailable")])

      assert {:ok, result} = verify(F.repack(f, report))
      refute result.environment_ready
    end

    assert {:error, _} = verify(F.repack(f, Map.put(f.report, "current_dev_sha", "invalid")))
  end

  test "identity schema duplicate keys and producer decisions fail closed", %{f: f} do
    for {key, value} <- [
          {"schema_version", 2},
          {"schema_version", 1.0},
          {"repository", "other/app"},
          {"workflow", "other.yml"},
          {"sha", F.sha("b")},
          {"run_id", 20},
          {"run_id", "020"},
          {"run_attempt", "1junk"},
          {"event", "pull_request"},
          {"workflow_ref", "other@ref"},
          {"ref", "refs/heads/main"},
          {"manual_validation", "passed"},
          {"next_task_allowed", true},
          {"jobs", []},
          {"errors", "bad"},
          {"observed_at", "invalid"},
          {"observed_at", "2026-09-16T09:59:00Z"},
          {"observed_at", nil},
          {"extra", true}
        ] do
      assert {:error, _} = verify(F.repack(f, Map.put(f.report, key, value))), inspect({key, value})
    end

    raw = String.replace_prefix(Jason.encode!(f.report), "{", "{\"run_id\":\"20\",")
    zip = F.zip(raw)
    assert {:error, :invalid_delivery_json} = verify(%{f | zip: zip, artifact: F.artifact(zip)})
    assert {:error, _} = verify(F.repack(f, Map.delete(f.report, "jobs")))
    assert {:error, _} = Evidence.verify(f.zip, nil, f.run, f.jobs, f.policy, f.settings)
  end

  test "GitHub identity and immutable artifact metadata must match", %{f: f} do
    for {key, value} <- [{"expired", true}, {"id", 0}, {"name", "development-evidence-20-2"}, {"size_in_bytes", 0}, {"size_in_bytes", 5_242_881}, {"digest", "sha256:wrong"}, {"workflow_run", %{}}] do
      assert {:error, _} = verify(%{f | artifact: Map.put(f.artifact, key, value)})
    end

    for {key, value} <- [{"id", 21}, {"head_sha", F.sha("b")}, {"repository_id", 99}, {"head_repository_id", 99}, {"head_branch", "main"}] do
      assert {:error, _} = verify(%{f | artifact: put_in(f.artifact, ["workflow_run", key], value)})
    end
  end

  test "one green flag cannot replace jobs, required steps or collector publication", %{f: f} do
    for jobs <- [
          tl(f.jobs),
          [hd(f.jobs) | f.jobs],
          Enum.map(f.jobs, &Map.put(&1, "run_attempt", 2)),
          Enum.map(f.jobs, &Map.put(&1, "head_sha", F.sha("b"))),
          Enum.map(f.jobs, &Map.put(&1, "conclusion", "neutral")),
          Enum.map(f.jobs, &Map.put(&1, "steps", [])),
          Enum.map(f.jobs, &Map.update!(&1, "steps", fn steps -> [hd(steps) | steps] end)),
          Enum.map(f.jobs, fn job -> if job["name"] == "Development evidence", do: Map.put(job, "conclusion", "failure"), else: job end)
        ] do
      assert {:error, _} = verify(%{f | jobs: jobs})
    end

    for {path, value} <- [
          {["jobs", "verify", "steps", "complete", "outcome"], "failure"},
          {["jobs", "verify", "steps", "complete", "conclusion"], "neutral"},
          {["jobs", "verify", "admitted"], false},
          {["jobs", "verify", "success"], false},
          {["jobs", "verify", "checkout_sha"], F.sha("b")},
          {["jobs", "verify", "errors"], ["failure"]},
          {["jobs", "verify", "facts"], %{"unexpected" => true}},
          {["jobs", "verify", "schema_version"], 0},
          {["jobs", "queue_pause", "facts", "guard_established"], "false"},
          {["jobs", "scheduler_finalize", "facts", "state"], "unknown"},
          {["jobs", "queue_finalize", "facts", "reason"], "protective_pause"},
          {["jobs", "scheduler_finalize", "steps", "refreeze_cron", "conclusion"], "success"}
        ] do
      assert {:error, _} = verify(F.repack(f, put_in(f.report, path, value))), inspect(path)
    end

    assert {:error, _} = verify(F.repack(f, update_in(f.report, ["jobs"], &Map.delete(&1, "verify"))))
  end

  test "failure and unconfirmed reports remain blocked, even when receipt verification is partial", %{f: f} do
    report =
      f.report
      |> Map.put("deployment", "failure")
      |> Map.put("errors", ["job_incomplete:verify"])
      |> put_in(["jobs", "verify", "success"], false)
      |> put_in(["environment", "status"], "blocked")
      |> put_in(["environment", "blockers"], ["deployment_not_successful"])

    f = F.repack(%{f | run: Map.put(f.run, "conclusion", "failure")}, report)
    assert {:ok, result} = verify(f)
    refute result.complete
    refute result.environment_ready
    assert result.deployment == "failure"
    report = Map.put(report, "deployment", "unconfirmed")
    assert {:ok, result} = verify(F.repack(%{f | run: Map.put(f.run, "conclusion", "neutral")}, report))
    assert result.deployment == "unconfirmed"
  end

  test "approved YAML binds reusable jobs and explicit environment variants", %{f: f, cache: cache} do
    assert {:ok, policy} = Policy.load(F.client(f, cache))
    assert policy.jobs["verify"].name == "Verify release / Verify application"
    assert :ok = Policy.verify_sources(F.client(f, cache), policy, F.sha())
    assert :ok = Policy.verify_sources(F.client(f, cache), policy, F.sha("b"))
    path = f.settings.policy["deployment_workflow"]
    workflow = Jason.decode!(f.sources[path])
    modified = put_in(workflow, ["jobs", "queue_pause", "environment"], %{"name" => "development-containers"})
    assert {:ok, p} = Policy.parse(Map.put(f.sources, path, Jason.encode!(modified)), f.settings)
    assert p.jobs["queue_pause"].environment == "development-containers"
    f = %{f | sources: Map.put(f.sources, path, "changed")}
    assert {:error, :workflow_policy_changed} = Policy.verify_sources(F.client(f, cache), policy, F.sha("b"))
  end

  test "workflow ambiguity cannot reduce the approved checks", %{f: f} do
    p = f.settings.policy

    for {path, change} <- [
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "queue_pause", "environment"], "production") end},
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "queue_pause", "environment"], "${{ inputs.environment }}") end},
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "queue_pause", "name"], "scheduler_freeze") end},
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "queue_pause", "steps"], []) end},
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "queue_pause", "steps"], [%{"name" => "same"}, %{"name" => "same"}]) end},
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "queue_pause", "steps"], [%{"name" => "one", "id" => "same"}, %{"name" => "two", "id" => "same"}]) end},
          {p["deployment_workflow"], fn w -> put_in(w, ["jobs", "verify", "uses"], "external.yml") end},
          {p["verify_workflow"], fn w -> put_in(w, ["jobs", "extra"], %{}) end},
          {p["pr_workflow"], fn w -> put_in(w, ["jobs", "result", "name"], "verify / Verify application") end}
        ] do
      sources = Map.update!(f.sources, path, &(Jason.decode!(&1) |> change.() |> Jason.encode!()))
      assert {:error, :invalid_delivery_policy} = Policy.parse(sources, f.settings)
    end

    for jobs <- [nil, %{}, %{"verify" => %{}}, %{"strange" => %{"required_steps" => nil}}] do
      spec = %{f.policy.spec | "jobs" => jobs} |> Jason.encode!()
      settings = put_in(f.settings, [:policy, "contract_sha256"], Policy.hash(spec))
      assert {:error, _} = Policy.parse(Map.put(f.sources, p["contract_path"], spec), settings)
    end

    assert {:error, _} = Policy.parse(Map.put(f.sources, p["contract_path"], "{}"), f.settings)
    assert {:error, _} = Policy.parse(Map.put(f.sources, p["pr_workflow"], "- list\n"), f.settings)
    assert {:error, _} = Policy.parse(Map.put(f.sources, p["verify_workflow"], "bad: [\n"), f.settings)
  end

  test "bounded JSON rejects duplicate nested keys and malformed or oversized input" do
    assert {:ok, %{"x" => [%{"n" => 1}, true, nil]}} = JSON.decode(~s({"x":[{"n":1},true,null]}))

    for raw <- [~s({"x":1,"x":2}), ~s({"x":[{"n":1,"n":2}]}), "{", nil, String.duplicate(" ", 100)] do
      assert {:error, :invalid_delivery_json} = JSON.decode(raw, 50)
    end
  end

  test "ZIP rejects wrong hashes unsafe names extra entries and malformed central directory" do
    raw = String.duplicate("payload ", 500)

    for opts <- [[], [compress: []]] do
      zip = F.zip(raw, opts)
      assert {:ok, ^raw} = Archive.read(zip, digest(zip))
    end

    assert {:error, _} = Archive.read("short", "wrong")
    zip = F.zip(raw)
    assert {:error, _} = Archive.read(zip, "wrong")

    for bytes <- [binary_part(zip, 0, byte_size(zip) - 1), zip <> "comment", String.replace(zip, "development-evidence.json", "../evil-evidence-file.txt")] do
      assert {:error, _} = Archive.read(bytes, digest(bytes))
    end

    {:ok, {_, zip}} = :zip.create(~c"two.zip", [{~c"development-evidence.json", raw}, {~c"other", raw}], [:memory])
    assert {:error, _} = Archive.read(zip, digest(zip))
    zip = F.zip(String.duplicate("a", 2_097_153))
    assert {:error, _} = Archive.read(zip, digest(zip))
  end

  defp verify(f), do: Evidence.verify(f.zip, f.artifact, f.run, f.jobs, f.policy, f.settings)
  defp digest(bytes), do: "sha256:" <> Policy.hash(bytes)
end
