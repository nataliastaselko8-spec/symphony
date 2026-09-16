defmodule SymphonyElixir.DeliveryClientTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.DeliveryObserverSupport, as: F
  alias SymphonyElixir.GitHubProjects.Delivery.Client

  setup do
    f = F.fixture()
    cache = start_supervised!(F.Cache)
    %{f: f, client: F.client(f, cache)}
  end

  test "collection completeness, repeated pages and late failure", %{client: client} do
    entries = Enum.map(1..101, &%{"id" => &1})
    client = http(client, fn opts -> F.page("workflow_runs", entries, opts) end)
    assert {:ok, ^entries} = Client.list(client, :runs, [10])
    assert {:error, :observation_page_limit} = Client.list(%{client | opts: Keyword.put(client.opts, :max_pages, 1)}, :runs, [10])
    assert {:ok, ^entries} = Client.list(http(client, fn opts -> F.ok(Enum.slice(entries, (opts[:params][:page] - 1) * 100, 100)) end), :pulls)
    first = Enum.take(entries, 100)

    for body <- [
          %{"total_count" => 101, "workflow_runs" => first},
          %{"total_count" => 99, "workflow_runs" => first},
          %{"total_count" => 1, "workflow_runs" => [%{"id" => 0}]},
          %{"total_count" => 101, "workflow_runs" => []},
          %{"workflow_runs" => []},
          [],
          "invalid"
        ] do
      assert {:error, _} = Client.list(http(client, fn _ -> F.ok(body) end), :runs, [10])
    end

    late = fn opts ->
      if opts[:params][:page] == 1,
        do: F.ok(%{"total_count" => 101, "workflow_runs" => first}),
        else: {:ok, %{status: 403, headers: %{"retry-after" => ["120"]}, body: "limited"}}
    end

    assert {:error, {:github_delivery_limited, 120}} = Client.list(http(client, late), :runs, [10])
    oversized_page = Enum.map(1..101, &%{"id" => &1})
    assert {:error, :invalid_collection} = Client.list(http(client, fn _ -> F.ok(oversized_page) end), :pulls)
  end

  test "only fixed operations are accepted and contents are decoded safely", %{f: f, client: client} do
    assert {:ok, bytes} = Client.content(client, f.settings.policy["contract_path"], F.sha())
    assert bytes == f.sources[f.settings.policy["contract_path"]]

    invalid = [
      {:delete, []},
      {:workflow, ["arbitrary.yml"]},
      {:content, ["../../secret", F.sha()]},
      # Invalid identities cannot form a GitHub URL.
      {:compare, ["bad", F.sha()]},
      {:commit, ["bad"]},
      {:pull, [0]},
      {:jobs, [1, 0]}
    ]

    for {op, args} <- invalid do
      assert {:error, :invalid_delivery_operation} = Client.fetch(client, op, args)
    end

    assert {:error, :invalid_delivery_operation} = Client.list(client, :arbitrary)
    path = f.settings.policy["contract_path"]

    for body <- [%{}, %{"type" => "file", "path" => path, "encoding" => "base64", "content" => "not-base64"}] do
      assert {:error, :content_unavailable} = Client.content(http(client, fn _ -> F.ok(body) end), path, F.sha())
    end
  end

  test "one transient GET retry, deadline and safe error messages", %{client: client} do
    counter = :atomics.new(1, [])

    retry = fn _ ->
      if :atomics.add_get(counter, 1, 1) == 1, do: {:error, "secret-network-error"}, else: F.ok(%{"ok" => true})
    end

    assert {:ok, %{"ok" => true}} = Client.fetch(http(client, retry), :repo)
    assert :atomics.get(counter, 1) == 2
    assert {:error, :observation_deadline} = Client.fetch(%{client | deadline: client.now.() - 1}, :repo)

    callbacks = [
      fn _ -> raise "private" end,
      fn _ -> throw("private") end,
      # The transport can fail without returning the expected tuple.
      fn _ -> :malformed end,
      fn _ -> F.ok(String.duplicate("x", 5_242_881), false) end
    ]

    for callback <- callbacks do
      assert {:error, :github_delivery_response_unavailable} = Client.fetch(http(client, callback), :repo)
    end

    statuses = [
      {401, :github_delivery_unauthorized},
      {403, {:github_delivery_http, 403}},
      {404, {:github_delivery_http, 404}},
      # Service and rate-limit failures preserve a bounded diagnosis.
      {503, {:github_delivery_http, 503}},
      {429, {:github_delivery_limited, 60}}
    ]

    for {status, expected} <- statuses do
      result = Client.fetch(http(client, fn _ -> {:ok, %{status: status, body: "private", headers: %{}}} end), :repo)
      assert result == {:error, expected}
    end

    for value <- ["bad", "-1"] do
      assert {:error, {:github_delivery_limited, 60}} =
               Client.fetch(
                 http(client, fn _ ->
                   {:ok, %{status: 403, body: "", headers: %{"retry-after" => [value]}}}
                 end),
                 :repo
               )
    end

    reset = System.system_time(:second) + 600

    assert {:error, {:github_delivery_limited, seconds}} =
             Client.fetch(
               http(client, fn _ ->
                 {:ok, %{status: 403, body: "", headers: %{"x-ratelimit-reset" => [to_string(reset)], "x-ratelimit-remaining" => ["0"]}}}
               end),
               :repo
             )

    assert seconds in 598..600
  end

  test "download checks the destination, strips auth and rejects another redirect", %{f: f, client: client} do
    assert {:ok, zip} = Client.download(client, 30)
    assert zip == f.zip
    assert {:error, _} = Client.download(client, -1)

    for url <- [
          nil,
          "http://productionresultsx.blob.core.windows.net/a",
          "https://localhost/a",
          "https://productionresultsx.blob.core.windows.net.attacker.invalid/a",
          "https://user@productionresultsx.blob.core.windows.net/a",
          "https://productionresultsx.blob.core.windows.net:8443/a",
          "https://productionresultsx.blob.core.windows.net/a#fragment"
        ] do
      refute Client.storage_url?(url)
      bad = fn _ -> {:ok, %{status: 302, body: "", headers: %{"location" => [url]}}} end
      assert {:error, _} = Client.download(http(client, bad), 30)
    end

    again = fn opts ->
      if URI.parse(opts[:url]).host == "api.github.com",
        do: F.response(f, opts),
        else: {:ok, %{status: 302, body: "", headers: %{"location" => ["https://attacker.invalid/"]}}}
    end

    assert {:error, :artifact_download_invalid} = Client.download(http(client, again), 30)
  end

  test "bounded streaming halts before accumulating an oversized body", %{client: client} do
    streaming = fn opts ->
      fun = opts[:into]
      {:cont, {request, response}} = fun.({:data, "{}"}, {:request, %{body: ""}})
      assert request == :request
      {:halt, {_, response}} = fun.({:data, String.duplicate("x", 5_242_880)}, {request, response})
      {:ok, Map.put(response, :status, 200)}
    end

    assert {:error, :github_delivery_response_unavailable} = Client.fetch(http(client, streaming), :repo)
  end

  test "real Req transport uses the fixed request and injected adapter", %{client: client} do
    adapter = fn request ->
      assert request.method == :get
      assert request.url.host == "api.github.com"
      {request, Req.Response.new(status: 200, body: "{}")}
    end

    client = %{client | opts: client.opts |> Keyword.delete(:http) |> Keyword.put(:req_adapter, adapter)}
    assert {:ok, %{}} = Client.fetch(client, :repo)
  end

  defp http(client, fun), do: %{client | opts: Keyword.put(client.opts, :http, fun)}
end
