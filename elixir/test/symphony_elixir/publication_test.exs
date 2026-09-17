defmodule SymphonyElixir.PublicationTest.Publisher do
  def candidate(_, _, effect, _), do: {:ok, %{proof: %{"sha" => effect["payload"]["sha"], "digest" => String.duplicate("d", 64)}}}
  def push(_, candidate, opts), do: {:ok, Keyword.get(opts, :pushed_proof, candidate.proof)}
end

defmodule SymphonyElixir.PublicationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.DeliveryGateSupport, as: G
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.{Adapter, AgentTool, GitPublisher, Publication, WriteClient}

  setup do
    f = F.fixture()
    cycle = G.initial()["cycle"]

    row = %{
      "item_id" => "item-A",
      "state" => "Ready for agent",
      "archived" => false,
      "issue_state" => "OPEN",
      "reasons" => [],
      "native_ref" => %{"issue_id" => "issue-A", "repo" => f.settings.repo, "agent_allowed_option_id" => "yes"}
    }

    report = %{
      "items" => [row],
      "project" => %{"id" => "project"},
      "schema" => %{"agent_allowed_option_id" => "yes", "status" => %{"id" => "status", "options" => Enum.map(f.settings.project.states, fn {id, name} -> %{"id" => id, "name" => name} end)}}
    }

    initial = %{report: report, comments: [], links: [], prs: [], writes: [], dev: G.sha(), head: G.sha("b")}
    initial = Map.put(initial, :failure, nil)
    remote = start_supervised!({Agent, fn -> initial end})
    cache = start_supervised!(F.Cache)

    opts = [
      credentials_cache: cache,
      http: fn options -> http(remote, options) end,
      project_reader: fn _, _ -> {:ok, Agent.get(remote, & &1.report)} end,
      publisher: SymphonyElixir.PublicationTest.Publisher,
      base_sha: G.sha()
    ]

    effect = %{
      "operation_id" => "pub",
      "kind" => "publish",
      "payload" => %{"sha" => G.sha("b"), "title" => "Feature", "body" => "Changes and validation"},
      "steps" => %{},
      "submitted" => true,
      "cancelled" => false
    }

    %{settings: f.settings, cycle: cycle, effect: effect, remote: remote, opts: opts, client: WriteClient.new(f.settings, cycle, opts)}
  end

  defp http(remote, options) do
    assert options[:retry] == false
    assert options[:redirect] == false
    assert URI.parse(options[:url]).host == "api.github.com"
    state = Agent.get(remote, & &1)
    if state.failure, do: state.failure, else: response(remote, state, options)
  end

  defp response(remote, state, options) do
    path = URI.parse(options[:url]).path

    cond do
      String.ends_with?(path, "/git/ref/heads/dev") ->
        F.ok(%{"ref" => "refs/heads/dev", "object" => %{"type" => "commit", "sha" => state.dev}})

      String.contains?(path, "/git/ref/heads/agent/") ->
        F.ok(%{"ref" => "refs/heads/agent/task-a", "object" => %{"type" => "commit", "sha" => state.head}})

      String.ends_with?(path, "/pulls") and options[:method] == :get ->
        assert options[:params][:state] == "all"
        assert options[:params][:head] == "ExampleOrg:agent/task-a"
        F.ok(state.prs)

      String.ends_with?(path, "/pulls") ->
        body = options[:json]
        assert body["base"] == "dev"
        assert body["head"] == "agent/task-a"
        assert body["draft"] == false
        pr = Map.merge(F.pr(), %{"id" => 7, "node_id" => "pr-node", "body" => body["body"], "merged_at" => nil})
        Agent.update(remote, &%{&1 | prs: [pr], writes: &1.writes ++ [:pull]})
        F.ok(pr)

      path == "/graphql" ->
        graphql(remote, state, options[:json])
    end
  end

  defp graphql(remote, state, %{"query" => query, "variables" => vars}) do
    input = vars["input"]

    cond do
      String.starts_with?(query, "query") ->
        F.ok(%{
          "data" => %{
            "node" => %{
              "id" => "issue-A",
              "number" => 42,
              "state" => "OPEN",
              "repository" => %{"nameWithOwner" => "ExampleOrg/app"},
              "comments" => %{"nodes" => state.comments, "pageInfo" => %{"hasNextPage" => false}},
              "closedByPullRequestsReferences" => %{"nodes" => Enum.map(state.links, &%{"id" => &1}), "pageInfo" => %{"hasNextPage" => false}}
            }
          }
        })

      String.contains?(query, "SymphonyReport") ->
        if input["id"], do: assert(input["id"] == "comment"), else: assert(input["subjectId"] == "issue-A")
        comment = %{"id" => "comment", "body" => input["body"], "viewerDidAuthor" => true, "author" => %{"__typename" => "Bot"}}
        Agent.update(remote, &%{&1 | comments: [comment], writes: &1.writes ++ [:comment]})
        F.ok(%{"data" => %{}})

      String.contains?(query, "SymphonyLink") ->
        assert input["issueId"] == "issue-A"
        assert input["pullRequestIds"] == ["pr-node"]
        Agent.update(remote, &%{&1 | links: ["pr-node"], writes: &1.writes ++ [:link]})
        F.ok(%{"data" => %{}})

      String.contains?(query, "SymphonyStatus") ->
        assert input["itemId"] == "item-A" and input["fieldId"] == "status"
        option = Enum.find(state.report["schema"]["status"]["options"], &(&1["id"] == input["value"]["singleSelectOptionId"]))
        report = update_in(state.report, ["items"], fn [row] -> [Map.put(row, "state", option["name"])] end)
        Agent.update(remote, &%{&1 | report: report, writes: &1.writes ++ [:status]})
        F.ok(%{"data" => %{}})
    end
  end

  defp authorize(step, _),
    do:
      (
        send(self(), {:authorized, step})
        :ok
      )

  defp perform(c, effect), do: Publication.step(c.settings, c.cycle, effect, &authorize/2, c.opts)

  defp at(effect, step) do
    previous = ~w(push pull comment link status) |> Enum.take_while(&(&1 != step))
    entries = Map.new(previous, &{&1, %{"status" => "confirmed", "result" => %{"pr_id" => "pr-node"}}})
    %{effect | "steps" => entries}
  end

  test "publication writes one PR, one report and native link, then confirms handoff", c do
    {cycle, effect} =
      Enum.reduce(~w(push pull comment link status), {c.cycle, c.effect}, fn step, {cycle, effect} ->
        assert {:ok, ^step, result} = perform(%{c | cycle: cycle}, effect)
        assert_received {:authorized, ^step}
        updated = put_in(effect, ["steps", step], %{"status" => "confirmed", "result" => result})
        cycle = if step == "pull", do: put_in(cycle, ["work"], Map.merge(cycle["work"], Map.take(result, ~w(pr_number head_sha)))), else: cycle
        {cycle, updated}
      end)

    assert {:ok, "finalize", %{"pr_number" => 7}} = perform(%{c | cycle: cycle}, effect)
    assert Agent.get(c.remote, & &1.writes) == [:pull, :comment, :link, :status]
    assert Agent.get(c.remote, &hd(&1.prs)["body"]) =~ "https://github.com/ExampleOrg/app/issues/42"
  end

  test "lost PR response is reconciled without duplicate, closed or changed PR stops", c do
    effect = at(c.effect, "pull")
    assert {:ok, "pull", _} = perform(c, effect)
    sent = put_in(effect, ["steps", "pull"], %{"status" => "sent"})
    assert {:ok, "pull", _} = perform(c, sent)
    assert Agent.get(c.remote, & &1.writes) == [:pull]

    for mutation <- [fn pr -> Map.put(pr, "state", "closed") end, fn pr -> put_in(pr, ["base", "ref"], "main") end, fn pr -> Map.put(pr, "draft", true) end] do
      old = Agent.get(c.remote, & &1.prs)
      Agent.update(c.remote, &%{&1 | prs: Enum.map(old, mutation)})
      assert {:error, :publication_pr_changed} = perform(c, sent)
      Agent.update(c.remote, &%{&1 | prs: old})
    end

    Agent.update(c.remote, &%{&1 | prs: []})
    assert {:error, :publication_pr_unknown} = perform(c, sent)
  end

  test "comment retries use exact body and author, then update the same comment", c do
    effect = %{c.effect | "kind" => "report", "payload" => %{"body" => "Progress"}}
    assert {:ok, "comment", %{"comment_id" => "comment"}} = perform(c, effect)
    sent = put_in(effect, ["steps", "comment"], %{"status" => "sent"})
    assert {:ok, "comment", _} = perform(c, sent)
    assert Agent.get(c.remote, & &1.writes) == [:comment]
    updated = put_in(effect, ["payload", "body"], "New progress")
    assert {:error, :publication_report_unknown} = perform(c, put_in(sent, ["payload", "body"], "New progress"))
    assert {:ok, "comment", _} = perform(c, updated)
    Agent.update(c.remote, fn s -> %{s | comments: Enum.map(s.comments, &Map.put(&1, "viewerDidAuthor", false))} end)
    assert {:error, :publication_report_changed} = perform(c, updated)
  end

  test "no send is repeated for ambiguous push, native link or status", c do
    push = c.effect |> Map.put("candidate", %{"digest" => String.duplicate("d", 64), "base_sha" => G.sha()}) |> put_in(["steps", "push"], %{"status" => "sent"})
    assert {:ok, "push", %{"sha" => sha}} = perform(c, push)
    assert sha == G.sha("b")
    Agent.update(c.remote, &%{&1 | head: G.sha("c")})
    assert {:error, :publication_push_unknown} = perform(c, push)

    for {step, reason} <- [{"link", :publication_link_unknown}, {"status", :publication_status_unknown}] do
      effect = at(c.effect, step) |> put_in(["steps", step], %{"status" => "sent"})
      assert {:error, ^reason} = perform(c, effect)
    end

    refute_received {:authorized, _}
  end

  test "a changed push receipt, duplicate PRs and missing write readback retain unknown outcome", c do
    assert {:error, :publication_push_unknown} = perform(%{c | opts: Keyword.put(c.opts, :pushed_proof, %{})}, c.effect)
    reject = fn _, _ -> {:error, :cancelled} end
    assert {:error, :cancelled} = Publication.step(c.settings, c.cycle, c.effect, reject, c.opts)
    Agent.update(c.remote, &%{&1 | prs: [F.pr(), Map.put(F.pr(), "id", 8)]})
    assert {:error, :publication_pr_ambiguous} = perform(c, at(c.effect, "pull"))

    http = fn opts ->
      query = get_in(opts, [:json, "query"]) || ""
      if String.starts_with?(query, "mutation"), do: F.ok(%{"data" => %{}}), else: http(c.remote, opts)
    end

    changed = %{c | opts: Keyword.put(c.opts, :http, http)}
    assert {:error, :publication_link_unknown} = perform(changed, at(c.effect, "link"))
    assert {:error, :publication_report_unknown} = perform(changed, at(c.effect, "comment"))
    Agent.update(c.remote, &%{&1 | links: ["pr-node"]})
    assert {:ok, "link", _} = perform(changed, at(c.effect, "link"))
  end

  test "fresh scope and dev are required even for a prepared request", c do
    Agent.update(c.remote, &%{&1 | dev: G.sha("c")})
    assert {:error, :publication_base_changed} = perform(c, c.effect)
    Agent.update(c.remote, &%{&1 | dev: G.sha(), report: put_in(&1.report, ["items", Access.at(0), "native_ref", "agent_allowed_option_id"], "no")})
    assert {:error, :publication_scope_changed} = perform(c, c.effect)
    refute_received {:authorized, _}
  end

  test "closing keywords and unknown destination fields are not passed to writes", c do
    effect = at(c.effect, "pull") |> put_in(["payload", "body"], "Closes #42")
    assert {:error, :closing_keywords_not_allowed} = perform(c, effect)
    assert Agent.get(c.remote, & &1.writes) == []
    assert {:error, :publication_status_unconfirmed} = WriteClient.status(c.client, %{schema: %{"status" => %{"options" => []}}}, "working")
  end

  test "transport errors and partial GraphQL data never authorize success", c do
    partial = F.ok(%{"data" => %{}, "errors" => [%{"message" => "failure"}]})
    responses = [{:error, :timeout}, {:ok, %{status: 302, body: "", headers: %{}}}, partial, F.ok(%{})]

    for response <- responses do
      Agent.update(c.remote, &%{&1 | failure: response})
      assert {:error, _} = WriteClient.issue(c.client)
    end

    Agent.update(c.remote, &%{&1 | failure: {:ok, %{status: 429, headers: %{"retry-after" => ["90"]}, body: ""}}})
    assert {:error, {:publication_limited, 90}} = WriteClient.issue(c.client)
    bad = %{c.client | opts: Keyword.put(c.opts, :http, fn _ -> raise "secret must not appear" end)}
    assert {:error, :publication_transport_unknown} = WriteClient.issue(bad)
  end

  test "tools expose only task operations and reject an absent or invalid session", c do
    names = Enum.map(AgentTool.specs(), & &1["name"])
    assert names == ~w(project_context project_start project_report project_block project_prepare_pr project_handoff)
    assert Adapter.agent_tool_specs() == AgentTool.specs()

    for name <- names ++ ~w(merge deploy rerun project_set_permission), handle <- [nil, %{}] do
      assert %{"success" => false} = AgentTool.execute(name, %{}, delivery: handle)
    end

    assert {:error, :candidate_transport_required} = GitPublisher.candidate(c.settings, c.cycle, c.effect, [])
    exporter = fn _, _ -> {:error, :transport_failed} end
    opts = [export_candidate: exporter]
    assert {:error, :transport_failed} = GitPublisher.candidate(c.settings, c.cycle, c.effect, opts)
    assert {:error, :git_publication_unconfirmed} = GitPublisher.run(%{"branch" => "main"})
  end

  test "finite pagination rejects truncated issue relations and duplicate pages", c do
    options = [method: :post, url: "https://api.github.com/graphql", json: %{"query" => "query", "variables" => %{}}, retry: false, redirect: false]
    {:ok, %{body: raw}} = http(c.remote, options)
    body = Jason.decode!(raw)
    node = body["data"]["node"]
    node = put_in(node, ["comments", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"})

    caller = fn opts ->
      next = if opts[:json]["variables"]["cursor"], do: put_in(node, ["comments", "pageInfo"], %{"hasNextPage" => false}), else: node
      F.ok(%{"data" => %{"node" => next}})
    end

    client = %{c.client | opts: Keyword.put(c.opts, :http, caller)}
    assert {:ok, %{comments: []}} = WriteClient.issue(client)

    for changed <- [put_in(node, ["comments", "pageInfo"], %{"hasNextPage" => true}), put_in(node, ["closedByPullRequestsReferences", "pageInfo", "hasNextPage"], true)] do
      assert {:error, :publication_issue_unconfirmed} = WriteClient.issue(%{client | opts: Keyword.put(c.opts, :http, fn _ -> F.ok(%{"data" => %{"node" => changed}}) end)})
    end

    duplicates = put_in(body, ["data", "node", "comments", "nodes"], [%{"id" => "a"}, %{"id" => "a"}])
    assert {:error, :publication_comments_changed} = WriteClient.issue(%{client | opts: Keyword.put(c.opts, :http, fn _ -> F.ok(duplicates) end)})

    for response <- [F.ok([%{"id" => 1}, %{"id" => 1}]), {:error, :timeout}] do
      assert {:error, _} = WriteClient.pulls(%{client | opts: Keyword.put(c.opts, :http, fn _ -> response end)})
    end
  end

  test "bounded response collector, exceptions, scoped item selection and invalidation", c do
    caller = fn opts ->
      assert {:cont, {nil, %{body: "ok"}}} = opts[:into].({:data, "ok"}, {nil, %{body: "", status: 200}})
      data = String.duplicate("x", 5_242_881)
      assert {:halt, {nil, %{status: 413, body: ""}}} = opts[:into].({:data, data}, {nil, %{body: "", status: 200}})
      throw(:disconnected)
    end

    assert {:error, :publication_transport_unknown} = WriteClient.issue(%{c.client | opts: Keyword.put(c.opts, :http, caller)})
    Agent.update(c.remote, &%{&1 | failure: {:ok, %{status: 403, headers: %{"retry-after" => ["bad"]}}}})
    assert {:error, {:publication_limited, 60}} = WriteClient.issue(c.client)
    Agent.update(c.remote, &%{&1 | failure: {:ok, %{status: 401, body: "", headers: %{}}}})
    assert {:error, :publication_result_unknown} = WriteClient.issue(c.client)
    client = put_in(c.client, [:settings, :project, :item_ids], ["other"])
    assert {:error, :publication_scope_changed} = WriteClient.scope(client, ["Ready for agent"])
    opts = Keyword.put(c.opts, :project_reader, fn _, _ -> {:error, :incomplete} end)
    assert {:error, :incomplete} = WriteClient.scope(%{c.client | opts: opts}, ["Ready for agent"])
  end

  test "controller verifies a real immutable bundle and handles helper disconnect or timeout", c do
    root = Path.join(System.tmp_dir!(), "publisher-elixir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    git = fn args ->
      {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
      String.trim(output)
    end

    git.(["init", "-b", "dev"])
    File.write!(Path.join(root, "app.txt"), "base")
    git.(["add", "."])
    git.(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Base"])
    sha = git.(["rev-parse", "HEAD"])
    git.(["branch", "agent/task-a"])
    bundle = Path.join(root, "candidate.bundle")
    git.(["bundle", "create", bundle, "agent/task-a"])
    effect = put_in(c.effect, ["payload", "sha"], sha)
    opts = Keyword.merge(c.opts, base_sha: sha, export_candidate: fn _, ^sha -> {:ok, bundle} end)
    assert {:ok, candidate} = GitPublisher.candidate(c.settings, c.cycle, effect, opts)
    assert candidate.proof["sha"] == sha
    changed = put_in(candidate, [:command, "bundle"], Path.join(root, "absent"))
    assert {:error, :git_publication_unconfirmed} = GitPublisher.push(c.settings, changed, c.opts)
    python = System.find_executable("python3")

    for {script, timeout, expected} <- [
          {"import sys; sys.stdin.buffer.read(4); sys.exit(7)", 2_000, :git_publication_unconfirmed},
          {"import sys; sys.stdin.buffer.read()", 10, :git_publication_timeout}
        ] do
      port = Port.open({:spawn_executable, python}, [:binary, {:packet, 4}, :use_stdio, :exit_status, {:args, ["-I", "-c", script]}])
      assert {:error, ^expected} = GitPublisher.exchange(port, %{}, timeout)
    end
  end
end
