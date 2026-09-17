defmodule SymphonyElixir.GitHubProjectsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubProjects.{Adapter, Client, Normalizer, Schema, Settings}
  alias SymphonyElixir.Tracker.Issue

  @fixture Path.expand("../fixtures/github_projects/snapshot.json", __DIR__)

  test "inspection reports board eligibility without execution, body, or credentials" do
    fixture = fixture()
    settings = settings()
    assert :ok = Adapter.validate_config(settings)
    assert Enum.map(Adapter.agent_tool_specs(), & &1["name"]) == ~w(project_context project_start project_report project_block project_prepare_pr project_handoff)
    assert %{"success" => false} = Adapter.execute_agent_tool("project_start", %{}, [])

    assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
    assert report["execution_enabled"] == false
    assert report["eligibility_scope"] == "project_fields_only"
    assert report["summary"] == %{"total" => 1, "eligible" => 1, "excluded" => 0}
    assert report["schema"]["status"]["id"] == "F_status"

    [row] = report["items"]
    assert row["eligible"]
    assert row["reasons"] == []
    assert row["native_ref"]["item_id"] == "PVTI_fixture_A"
    assert row["native_ref"]["issue_id"] == "I_fixture_17"
    assert row["native_ref"]["issue_number"] == 17
    assert row["native_ref"]["project_fields"]["Acceptance command"]["value"] =~ "not executed"

    json = Jason.encode!(report)
    refute json =~ settings.provider["token"]
    refute json =~ "Private fixture issue body"

    assert {:ok, [%Issue{} = issue]} =
             Client.fetch_issues_by_states(["Ready for agent"], tracker_settings: settings, request_fun: request_fun(fixture))

    assert issue.id == "PVTI_fixture_A"
    assert issue.state == "Ready for agent"
    assert issue.dispatchable
    assert issue.labels == ["feature"]
    assert issue.assignee_id == "fixture-owner"
    assert issue.priority == nil
    assert issue.blocked_by == []
    assert %DateTime{} = issue.created_at
    assert issue.description =~ "Private fixture issue body"
  end

  test "full field and item pagination includes archives and detects duplicate required names on later pages" do
    fixture = fixture()
    [item] = fixture["items"]
    second = item |> Map.put("id", "PVTI_fixture_B") |> Map.put("isArchived", true)
    fixture = Map.put(fixture, "items", [item, second])
    request = paginated_request(fixture)

    assert {:ok, report} = Client.inspect(settings(), request_fun: request)
    assert report["summary"]["total"] == 2
    assert Enum.at(report["items"], 1)["reasons"] == ["archived"]
    assert_received {:items_query, query}
    assert query =~ "archivedStates: [ARCHIVED, NOT_ARCHIVED]"

    duplicate = fixture["fields"] |> hd() |> Map.put("id", "F_duplicate")
    fixture = Map.update!(fixture, "fields", &(&1 ++ [duplicate]))

    assert {:error, {:github_projects_ambiguous_field, :status}} =
             Client.inspect(settings(), request_fun: paginated_request(fixture))
  end

  test "labels and assignees are completed beyond the first page before normalization" do
    fixture = fixture()

    fixture =
      fixture
      |> put_in(["items", Access.at(0), "content", "labels", "pageInfo"], page_info("labels-next"))
      |> put_in(["items", Access.at(0), "content", "assignees", "pageInfo"], page_info("assignees-next"))

    request = fn query, variables, settings ->
      if query =~ "SymphonyIssueConnection" do
        connection = if query =~ "labels(first", do: "labels", else: "assignees"
        field = if connection == "labels", do: "name", else: "login"
        assert variables["id"] == "I_fixture_17"
        assert variables["cursor"] in ["labels-next", "assignees-next"]

        ok(%{"node" => %{"__typename" => "Issue", "id" => "I_fixture_17", connection => connection([%{field => "second"}])}})
      else
        request_fun(fixture).(query, variables, settings)
      end
    end

    settings = Map.put(settings(), :required_labels, ["second"])
    assert {:ok, report} = Client.inspect(settings, request_fun: request)
    assert hd(report["items"])["eligible"]

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states(["Ready for agent"], tracker_settings: settings, request_fun: request)

    assert issue.labels == ["feature", "second"]
    assert issue.assignee_id == "fixture-owner"
  end

  test "permission values are bound to the discovered field and option, not only the displayed yes" do
    for {value, reason} <- [
          {nil, "missing_agent_allowed"},
          {select("F_allowed", "A_no", "no"), "agent_not_allowed"},
          {select("F_allowed", "unknown", "yes"), "invalid_agent_allowed"},
          {select("F_allowed", "A_no", "yes"), "invalid_agent_allowed"},
          {select("F_allowed", "A_yes", ""), "invalid_agent_allowed"}
        ] do
      fixture = put_in(fixture(), ["items", Access.at(0), "field_1"], value)
      assert {:ok, report} = Client.inspect(settings(), request_fun: request_fun(fixture))
      refute hd(report["items"])["eligible"]
      assert reason in hd(report["items"])["reasons"]

      assert {:ok, [issue]} =
               Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request_fun(fixture))

      refute issue.dispatchable
    end

    fixture = put_in(fixture(), ["items", Access.at(0), "field_1"], select("F_wrong", "A_yes", "yes"))

    assert {:error, :github_projects_field_identity_mismatch} =
             Client.inspect(settings(), request_fun: request_fun(fixture))
  end

  test "missing or invalid status is reported without invented state and refresh fails" do
    for {value, reason} <- [{nil, "missing_status"}, {select("F_status", "unknown", "Ready for agent"), "invalid_status"}] do
      fixture = put_in(fixture(), ["items", Access.at(0), "field_0"], value)
      assert {:ok, report} = Client.inspect(settings(), request_fun: request_fun(fixture))
      assert hd(report["items"])["state"] == nil
      assert reason in hd(report["items"])["reasons"]

      assert {:ok, []} =
               Client.fetch_issues_by_states(["Ready for agent"], tracker_settings: settings(), request_fun: request_fun(fixture))

      assert {:error, :github_projects_invalid_refresh_status} =
               Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request_fun(fixture))
    end
  end

  test "closed, archived, draft, pull request, redacted, inactive and wrong repository items are not eligible" do
    [item] = fixture()["items"]

    cases = [
      {put_in(item, ["content", "state"], "CLOSED"), "closed_issue"},
      {Map.put(item, "isArchived", true), "archived"},
      {Map.put(item, "content", %{"__typename" => "DraftIssue"}), "draft_item"},
      {Map.put(item, "content", %{"__typename" => "PullRequest"}), "pull_request_item"},
      {Map.put(item, "content", nil), "redacted_content"},
      {Map.put(item, "field_0", select("F_status", "S_5", "Done")), "inactive_status"},
      {put_in(item, ["content", "repository", "nameWithOwner"], "ExampleOrg/other"), "outside_repo_scope"},
      {put_in(item, ["project", "id"], "PVT_other"), "outside_project_scope"}
    ]

    for {item, reason} <- cases do
      fixture = Map.put(fixture(), "items", [item])
      assert {:ok, report} = Client.inspect(settings(), request_fun: request_fun(fixture))
      refute hd(report["items"])["eligible"]
      assert reason in hd(report["items"])["reasons"]
    end

    done = item |> Map.put("field_0", select("F_status", "S_5", "Done")) |> Map.put("isArchived", true)
    fixture = Map.put(fixture(), "items", [done])

    assert {:ok, [issue]} =
             Client.fetch_issues_by_ids([done["id"]], tracker_settings: settings(), request_fun: request_fun(fixture))

    assert issue.state == "Done"
    refute issue.dispatchable

    assert {:ok, [_issue]} =
             Client.fetch_issues_by_states(["Done"], tracker_settings: settings(), request_fun: request_fun(fixture))
  end

  test "an exact item filter excludes a re-added issue and preserves distinct workspace identity" do
    [item] = fixture()["items"]
    readded = Map.put(item, "id", "PVTI_fixture-B")
    fixture = Map.put(fixture(), "items", [item, readded])
    settings = put_in(settings(), [:provider, "item_ids"], [item["id"], "PVTI_missing"])
    assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
    [first, second] = report["items"]
    assert first["identifier"] != second["identifier"]
    assert second["reasons"] == ["outside_item_scope"]
    assert %{"code" => "missing_selected_item", "item_id" => "PVTI_missing"} in report["diagnostics"]

    assert {:ok, [issue]} =
             Client.fetch_issues_by_ids([item["id"], readded["id"]],
               tracker_settings: settings,
               request_fun: request_fun(fixture)
             )

    assert issue.id == item["id"]
    settings = put_in(settings.provider["item_ids"], [])
    assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
    assert report["summary"]["eligible"] == 0
  end

  test "required schema and options must be present, unambiguous, and single-select" do
    fixture = fixture()

    cases = [
      {Enum.drop(fixture["fields"], 1), {:github_projects_missing_field, :status}},
      {List.update_at(fixture["fields"], 0, &Map.put(&1, "dataType", "TEXT")), {:github_projects_wrong_field_type, :status}},
      {put_in(fixture["fields"], [Access.at(0), "options"], []), {:github_projects_missing_option, :status}},
      {put_in(fixture["fields"], [Access.at(1), "options"], []), {:github_projects_missing_option, :agent_allowed}},
      {put_in(fixture["fields"], [Access.at(1), "options"], [%{"id" => "A_one", "name" => "yes"}, %{"id" => "A_two", "name" => "yes"}]), {:github_projects_ambiguous_option, :agent_allowed}},
      {put_in(fixture["fields"], [Access.at(0), "options"], "bad"), {:github_projects_invalid_options, :status}}
    ]

    for {fields, reason} <- cases do
      assert {:error, ^reason} =
               Client.inspect(settings(), request_fun: request_fun(Map.put(fixture, "fields", fields)))
    end
  end

  test "optional fields produce diagnostics and never select an ambiguous field silently" do
    fixture = fixture()
    duplicate = fixture["fields"] |> List.last() |> Map.put("id", "F_other_acceptance")
    unsupported = %{"__typename" => "ProjectV2Field", "id" => "F_users", "name" => "Decision owner", "dataType" => "ASSIGNEES"}
    fixture = Map.update!(fixture, "fields", &(&1 ++ [duplicate, unsupported]))
    settings = put_in(settings(), [:provider, "context_fields"], ["Acceptance command", "Missing", "Decision owner"])
    assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))

    assert Enum.map(report["diagnostics"], & &1["code"]) ==
             ["ambiguous_context_field", "missing_context_field", "unsupported_context_field"]

    assert report["schema"]["context_fields"] == []
    assert hd(report["items"])["native_ref"]["project_fields"] == %{}
    assert hd(report["items"])["eligible"]
  end

  test "null node is absent only after a complete archived item inventory confirms it" do
    fixture = fixture()

    request = fn query, variables, settings ->
      if query =~ "SymphonyProjectNodes" do
        ok(%{"nodes" => Enum.map(variables["ids"], fn _id -> nil end)})
      else
        request_fun(fixture).(query, variables, settings)
      end
    end

    assert {:ok, []} =
             Client.fetch_issues_by_ids(["PVTI_deleted"], tracker_settings: settings(), request_fun: request)

    assert {:error, :github_projects_item_unavailable} =
             Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request)

    broken_inventory = fn query, variables, settings ->
      if query =~ "SymphonyProjectItemInventory",
        do: ok(%{"node" => nil}),
        else: request.(query, variables, settings)
    end

    assert {:error, :github_projects_scope_unavailable} =
             Client.fetch_issues_by_ids(["PVTI_deleted"], tracker_settings: settings(), request_fun: broken_inventory)
  end

  test "partial GraphQL data never becomes success or evidence of deletion and errors do not leak" do
    secret = settings().provider["token"]

    for operation <- ["SymphonyProjectIdentity", "SymphonyProjectFields", "SymphonyProjectItems", "SymphonyProjectNodes"] do
      request = fn query, variables, settings ->
        if query =~ operation do
          {:ok, %{status: 200, body: %{"data" => %{}, "errors" => [%{"message" => secret}]}}}
        else
          request_fun(fixture()).(query, variables, settings)
        end
      end

      result =
        if operation == "SymphonyProjectNodes",
          do: Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request),
          else: Client.inspect(settings(), request_fun: request)

      assert result == {:error, :github_projects_graphql_errors}
      refute inspect(result) =~ secret
    end

    for request <- [
          fn _, _, _ -> {:error, {:secret_transport_exception, secret}} end,
          fn _, _, _ -> raise secret end,
          fn _, _, _ -> throw(secret) end
        ] do
      assert Client.inspect(settings(), request_fun: request) == {:error, :github_projects_transport_error}
    end
  end

  test "pagination refuses missing, repeated, cyclic cursors, empty continued pages, and page limits" do
    fixture = fixture()

    for connection <- [
          %{"nodes" => fixture["fields"], "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}},
          %{"nodes" => [], "pageInfo" => page_info("next")},
          %{"nodes" => fixture["fields"], "pageInfo" => %{"hasNextPage" => "true", "endCursor" => "next"}}
        ] do
      request = override_fields(fixture, fn _cursor -> connection end)
      assert {:error, _reason} = Client.inspect(settings(), request_fun: request)
    end

    request = override_fields(fixture, fn _cursor -> connection(fixture["fields"], "same") end)
    assert {:error, :github_projects_incomplete_pagination} = Client.inspect(settings(), request_fun: request)

    request =
      override_fields(fixture, fn cursor ->
        next = if cursor == "one", do: "two", else: "one"
        connection(fixture["fields"], next)
      end)

    assert {:error, :github_projects_incomplete_pagination} = Client.inspect(settings(), request_fun: request)

    assert {:error, :github_projects_page_limit} =
             Client.inspect(settings(), request_fun: request, max_pages: 1)

    assert {:error, :github_projects_invalid_page_limit} =
             Client.inspect(settings(), request_fun: request, max_pages: 0)
  end

  test "malformed envelopes and scope identity fail safely; HTTP retry metadata is bounded data" do
    for body <- [%{}, %{"data" => nil}, %{"data" => %{}, "errors" => nil}, %{"data" => %{"organization" => "bad"}}] do
      request = fn _, _, _ -> {:ok, %{status: 200, body: body}} end
      assert {:error, _reason} = Client.inspect(settings(), request_fun: request)
    end

    assert {:error, {:github_projects_http, 429, 60}} =
             Client.inspect(settings(),
               request_fun: fn _, _, _ ->
                 {:ok, %{status: 429, headers: %{"retry-after" => ["60"]}, body: settings().provider["token"]}}
               end
             )

    assert {:error, {:github_projects_http, 403, nil}} =
             Client.inspect(settings(),
               request_fun: fn _, _, _ ->
                 {:ok, %{status: 403, headers: %{"retry-after" => "not seconds"}, body: "private"}}
               end
             )

    fixture = put_in(fixture(), ["identity", "repository", "nameWithOwner"], "ExampleOrg/other")
    assert {:error, :github_projects_scope_unavailable} = Client.inspect(settings(), request_fun: request_fun(fixture))
  end

  test "settings validate scope, state roles, and token references without exposing secrets" do
    assert :ok = Client.validate_settings(settings())

    for {key, value} <- [
          {"organization", ""},
          {"project_number", 0},
          {"repo", "OtherOrg/app"},
          {"token", "$GHP_READER_TEST_MISSING_SECRET"},
          {"fields", %{"status" => "Same", "agent_allowed" => "Same"}},
          {"agent_allowed_value", ""},
          {"states", %{"ready" => "Ready for agent"}},
          {"item_ids", nil},
          {"context_fields", "not a list"}
        ] do
      assert {:error, _reason} = Client.validate_settings(put_in(settings(), [:provider, key], value))
    end

    for tracker <- [
          Map.put(settings(), :active_states, ["Ready for agent"]),
          Map.put(settings(), :terminal_states, ["Agent working"]),
          Map.put(settings(), :terminal_states, []),
          %{provider: nil}
        ] do
      assert {:error, _reason} = Client.validate_settings(tracker)
    end

    names = Adapter.secret_environment_names(put_in(settings(), [:provider, "token"], "$PROJECT_READ_TOKEN"))
    assert "PROJECT_READ_TOKEN" in names
    assert "GITHUB_TOKEN" in names
    assert "GH_TOKEN" in names
  end

  test "indexed missing-node errors require a successful inventory before deletion is accepted" do
    request = fn query, variables, settings ->
      if query =~ "SymphonyProjectNodes" do
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{"nodes" => [nil]},
             "errors" => [%{"type" => "NOT_FOUND", "path" => ["nodes", 0], "message" => "private error"}]
           }
         }}
      else
        request_fun(fixture()).(query, variables, settings)
      end
    end

    assert {:ok, []} =
             Client.fetch_issues_by_ids(["PVTI_deleted"], tracker_settings: settings(), request_fun: request)

    assert {:error, :github_projects_item_unavailable} =
             Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request)

    failed_inventory = fn query, variables, settings ->
      if query =~ "SymphonyProjectItemInventory",
        do: {:error, :disconnected},
        else: request.(query, variables, settings)
    end

    assert {:error, :github_projects_transport_error} =
             Client.fetch_issues_by_ids(["PVTI_deleted"], tracker_settings: settings(), request_fun: failed_inventory)
  end

  test "redacted content stays readable with an explicit non-dispatchable placeholder" do
    fixture = put_in(fixture(), ["items", Access.at(0), "content"], nil)

    assert {:ok, [issue]} =
             Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request_fun(fixture))

    assert issue.title == "[unavailable issue content]"
    assert issue.native_ref["issue_id"] == nil
    refute issue.dispatchable
  end

  test "supported context types preserve typed values and malformed optional values are diagnosed" do
    cases = [
      {"TEXT", %{"__typename" => "ProjectV2ItemFieldTextValue", "text" => "data"}, "data"},
      {"NUMBER", %{"__typename" => "ProjectV2ItemFieldNumberValue", "number" => 7.5}, 7.5},
      {"DATE", %{"__typename" => "ProjectV2ItemFieldDateValue", "date" => "2026-09-15"}, "2026-09-15"},
      {"ITERATION", %{"__typename" => "ProjectV2ItemFieldIterationValue", "title" => "Week 1", "iterationId" => "IT_1"}, %{"id" => "IT_1", "title" => "Week 1"}},
      {"SINGLE_SELECT", select("F_context", "C_yes", "yes"), %{"option_id" => "C_yes", "name" => "yes"}}
    ]

    for {type, value, expected} <- cases do
      fixture = context_fixture(type, Map.put(value, "field", %{"id" => "F_context"}))
      settings = put_in(settings(), [:provider, "context_fields"], ["Context"])
      assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
      assert hd(report["items"])["native_ref"]["project_fields"]["Context"]["value"] == expected
      assert hd(report["items"])["diagnostics"] == []

      fixture = put_in(fixture, ["items", Access.at(0), "field_2"], nil)
      assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
      assert hd(report["items"])["diagnostics"] == [%{"code" => "empty_context_value", "field" => "Context"}]
      assert hd(report["items"])["eligible"]
    end

    for {type, value} <- [
          {"SINGLE_SELECT", %{"__typename" => "ProjectV2ItemFieldNumberValue", "number" => "invalid"}},
          {"SINGLE_SELECT", select("F_context", "unknown", "yes")},
          {"TEXT", %{"__typename" => "ProjectV2ItemFieldNumberValue", "number" => 7.5}}
        ] do
      value = Map.put(value, "field", %{"id" => "F_context"})
      fixture = context_fixture(type, value)
      settings = put_in(settings(), [:provider, "context_fields"], ["Context"])
      assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
      assert hd(report["items"])["diagnostics"] == [%{"code" => "invalid_context_value", "field" => "Context"}]
      assert hd(report["items"])["eligible"]
    end
  end

  test "malformed items and required field responses invalidate a snapshot" do
    [item] = fixture()["items"]

    for item <- [
          Map.delete(item, "id"),
          Map.delete(item, "content"),
          Map.delete(item, "field_0"),
          Map.put(item, "isArchived", nil),
          Map.put(item, "content", %{"__typename" => "Unknown"}),
          put_in(item, ["content", "number"], -1),
          put_in(item, ["content", "labels"], connection([%{"not_name" => "private"}])),
          put_in(item, ["content", "assignees"], connection([%{"login" => nil}]))
        ] do
      assert {:error, _reason} = Client.inspect(settings(), request_fun: request_fun(Map.put(fixture(), "items", [item])))
    end

    fixture = Map.put(fixture(), "items", [item, item])

    assert {:error, :github_projects_duplicate_or_invalid_items} =
             Client.inspect(settings(), request_fun: request_fun(fixture))

    duplicate = fixture()["fields"] |> hd() |> Map.put("name", "Another field")
    fixture = Map.update!(fixture(), "fields", &(&1 ++ [duplicate]))

    assert {:error, :github_projects_invalid_schema} =
             Client.inspect(settings(), request_fun: request_fun(fixture))
  end

  test "empty labels and assignees and malformed timestamps remain safe issue metadata" do
    fixture =
      fixture()
      |> put_in(["items", Access.at(0), "content", "labels"], connection([]))
      |> put_in(["items", Access.at(0), "content", "assignees"], connection([]))
      |> put_in(["items", Access.at(0), "content", "createdAt"], "invalid")
      |> put_in(["items", Access.at(0), "content", "updatedAt"], nil)

    assert {:ok, [issue]} =
             Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request_fun(fixture))

    assert issue.labels == []
    assert issue.assignee_id == nil
    assert issue.created_at == nil
    assert issue.updated_at == nil

    settings = Map.put(settings(), :required_labels, ["missing"])
    assert {:ok, report} = Client.inspect(settings, request_fun: request_fun(fixture))
    assert hd(report["items"])["reasons"] == ["missing_required_labels"]
    refute hd(report["items"])["eligible"]
  end

  test "additional invalid config shapes are rejected before HTTP" do
    for {key, value} <- [
          {"organization", 10},
          {"repo", nil},
          {"repo", "ExampleOrg"},
          {"token", nil},
          {"token", "$BAD-NAME"},
          {"fields", []},
          {"states", []},
          {"item_ids", [""]}
        ] do
      assert {:error, _reason} = Client.validate_settings(put_in(settings(), [:provider, key], value))
    end

    refute "BAD-NAME" in Adapter.secret_environment_names(put_in(settings(), [:provider, "token"], "$BAD-NAME"))
    assert {:error, :invalid_github_projects_item_ids} = Client.fetch_issues_by_ids([""])

    assert {:ok, []} =
             Client.fetch_issues_by_ids([], tracker_settings: settings(), request_fun: request_fun(fixture()))
  end

  defp context_fixture(type, value) do
    field = %{
      "__typename" => if(type == "SINGLE_SELECT", do: "ProjectV2SingleSelectField", else: "ProjectV2Field"),
      "id" => "F_context",
      "name" => "Context",
      "dataType" => type,
      "options" => [%{"id" => "C_yes", "name" => "yes"}]
    }

    fixture()
    |> Map.update!("fields", &(&1 ++ [field]))
    |> put_in(["items", Access.at(0), "field_2"], value)
  end

  test "Req transport keeps credentials on the fixed endpoint, does not redirect, and sanitizes failure" do
    request = fn request ->
      assert request.method == :post
      assert URI.to_string(request.url) == "https://api.github.com/graphql"
      assert Req.Request.get_header(request, "authorization") == ["Bearer " <> settings().provider["token"]]
      assert request.options[:redirect] == false
      assert request.options[:retry] == false
      body = Jason.decode!(request.body)
      {:ok, response} = request_fun(fixture()).(body["query"], body["variables"], %{endpoint: URI.to_string(request.url)})
      {request, Req.Response.new(status: response.status, body: response.body)}
    end

    assert {:ok, report} = Client.inspect(settings(), req_adapter: request)
    assert report["summary"]["eligible"] == 1

    redirect = fn request ->
      send(self(), :redirect_request)
      {request, Req.Response.new(status: 302, headers: [{"location", "https://untrusted.example"}], body: "private")}
    end

    assert {:error, {:github_projects_http, 302, nil}} = Client.inspect(settings(), req_adapter: redirect)
    assert_received :redirect_request
    refute_received :redirect_request

    broken = fn request -> {request, %Req.TransportError{reason: :econnrefused}} end
    assert {:error, :github_projects_transport_error} = Client.inspect(settings(), req_adapter: broken)
    assert {:error, :invalid_github_projects_organization} = Client.inspect(%{provider: %{}})
  end

  test "invalid nodes, typed GraphQL failures, and malformed connection members never authorize deletion" do
    for nodes <- [
          [],
          [%{"__typename" => "Issue", "id" => "PVTI_fixture_A"}],
          [%{"__typename" => "ProjectV2Item", "id" => "PVTI_other"}]
        ] do
      request = fn query, variables, settings ->
        if query =~ "SymphonyProjectNodes",
          do: ok(%{"nodes" => nodes}),
          else: request_fun(fixture()).(query, variables, settings)
      end

      assert {:error, :github_projects_invalid_nodes} =
               Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request)
    end

    for error <- [
          %{"type" => "FORBIDDEN", "path" => ["nodes", 0]},
          %{"type" => "NOT_FOUND", "path" => ["other", 0]},
          %{"type" => "NOT_FOUND", "path" => ["nodes", 1]}
        ] do
      request = fn query, variables, settings ->
        if query =~ "SymphonyProjectNodes",
          do: {:ok, %{status: 200, body: %{"data" => %{"nodes" => [nil]}, "errors" => [error]}}},
          else: request_fun(fixture()).(query, variables, settings)
      end

      assert {:error, :github_projects_graphql_errors} =
               Client.fetch_issues_by_ids(["PVTI_fixture_A"], tracker_settings: settings(), request_fun: request)
    end

    request = override_fields(fixture(), fn _cursor -> connection([nil]) end)
    assert {:error, :github_projects_invalid_connection} = Client.inspect(settings(), request_fun: request)

    assert {:error, :github_projects_invalid_response} =
             Client.inspect(settings(), request_fun: fn _, _, _ -> :unexpected end)
  end

  test "HTTP hints accept only numeric retry seconds and absent owner identity is rejected" do
    for {headers, expected} <- [
          {[{"x-other", "private"}, {"retry-after", "12"}], 12},
          {nil, nil},
          {%{}, nil}
        ] do
      assert {:error, {:github_projects_http, 503, ^expected}} =
               Client.inspect(settings(),
                 request_fun: fn _, _, _ ->
                   {:ok, %{status: 503, headers: headers, body: "private"}}
                 end
               )
    end

    fixture = put_in(fixture(), ["identity", "organization", "projectV2", "owner"], %{})
    assert {:error, :github_projects_scope_unavailable} = Client.inspect(settings(), request_fun: request_fun(fixture))
    assert "GITHUB_TOKEN" in Adapter.secret_environment_names(settings())
  end

  test "normalizer rejects incomplete hydrated metadata and invalid selected-value shapes" do
    fixture = fixture()
    {:ok, parsed} = Settings.parse(settings())
    {:ok, schema} = Schema.resolve(fixture["fields"], parsed)
    project = %{"id" => "PVT_fixture"}

    item =
      fixture["items"]
      |> hd()
      |> update_in(["content", "labels"], & &1["nodes"])
      |> update_in(["content", "assignees"], & &1["nodes"])

    for item <- [
          put_in(item, ["content", "labels"], nil),
          put_in(item, ["content", "assignees"], nil),
          put_in(item, ["content", "title"], nil)
        ] do
      assert {:error, :github_projects_invalid_issue} = Normalizer.normalize(item, project, schema, parsed)
    end

    item = Map.put(item, "field_1", %{"__typename" => "ProjectV2ItemFieldTextValue", "field" => %{"id" => "F_allowed"}})
    assert {:ok, {issue, row}} = Normalizer.normalize(item, project, schema, parsed)
    refute issue.dispatchable
    assert "invalid_agent_allowed" in row["reasons"]

    for field <- [
          put_in(hd(fixture["fields"]), ["options"], [nil]),
          Map.put(hd(fixture["fields"]), "id", nil)
        ] do
      fields = List.replace_at(fixture["fields"], 0, field)
      assert {:error, _reason} = Schema.resolve(fields, parsed)
    end
  end

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp settings do
    %{
      kind: "github_projects",
      provider: %{
        "organization" => "ExampleOrg",
        "project_number" => 1,
        "repo" => "ExampleOrg/app",
        "token" => "fixture-token-never-log-" <> String.duplicate("x", 180),
        "context_fields" => ["Acceptance command"]
      },
      active_states: ["Ready for agent", "Agent working"],
      terminal_states: ["Done"],
      required_labels: []
    }
  end

  defp request_fun(fixture) do
    fn query, variables, settings ->
      assert settings.endpoint == "https://api.github.com/graphql"
      assert String.starts_with?(String.trim(query), "query ")
      refute query =~ "mutation "

      cond do
        query =~ "SymphonyProjectIdentity" ->
          ok(fixture["identity"])

        query =~ "SymphonyProjectFields" ->
          project_connection("fields", connection(fixture["fields"]))

        query =~ "SymphonyProjectItems" ->
          project_connection("items", connection(fixture["items"]))

        query =~ "SymphonyProjectNodes" ->
          ok(%{
            "nodes" =>
              Enum.map(variables["ids"], fn id ->
                case Enum.find(fixture["items"], &(&1["id"] == id)) do
                  nil -> nil
                  item -> Map.put(item, "__typename", "ProjectV2Item")
                end
              end)
          })

        query =~ "SymphonyProjectItemInventory" ->
          assert query =~ "archivedStates: [ARCHIVED, NOT_ARCHIVED]"
          project_connection("items", connection(Enum.map(fixture["items"], &Map.take(&1, ["id"]))))

        true ->
          flunk("Unexpected fixture query")
      end
    end
  end

  defp paginated_request(fixture) do
    fn query, variables, settings ->
      cond do
        query =~ "SymphonyProjectFields" ->
          fields = fixture["fields"]
          page = split_page(fields, variables["cursor"], "fields-2")
          project_connection("fields", page)

        query =~ "SymphonyProjectItems" ->
          send(self(), {:items_query, query})
          items = fixture["items"]
          page = split_page(items, variables["cursor"], "items-2")
          project_connection("items", page)

        true ->
          request_fun(fixture).(query, variables, settings)
      end
    end
  end

  defp split_page(items, nil, next), do: connection(Enum.take(items, 1), next)
  defp split_page(items, _cursor, _next), do: connection(Enum.drop(items, 1))

  defp override_fields(fixture, pages) do
    fn query, variables, settings ->
      if query =~ "SymphonyProjectFields",
        do: project_connection("fields", pages.(variables["cursor"])),
        else: request_fun(fixture).(query, variables, settings)
    end
  end

  defp project_connection(name, connection),
    do: ok(%{"node" => %{"__typename" => "ProjectV2", "id" => "PVT_fixture", name => connection}})

  defp connection(nodes, next \\ nil), do: %{"nodes" => nodes, "pageInfo" => page_info(next)}
  defp page_info(nil), do: %{"hasNextPage" => false, "endCursor" => nil}
  defp page_info(cursor), do: %{"hasNextPage" => true, "endCursor" => cursor}
  defp ok(data), do: {:ok, %{status: 200, body: %{"data" => data}}}

  defp select(field, option, name),
    do: %{"__typename" => "ProjectV2ItemFieldSingleSelectValue", "field" => %{"id" => field}, "optionId" => option, "name" => name}
end

defmodule SymphonyElixir.GitHubProjectsDefaultReadsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProjects.Adapter

  test "default read callbacks reject a different tracker's workflow without making an HTTP request" do
    assert {:error, :invalid_github_projects_organization} = Adapter.fetch_issues_by_states(["Ready for agent"])
    assert {:error, :invalid_github_projects_organization} = Adapter.fetch_issues_by_ids(["PVTI_fixture_A"])
  end
end
