defmodule SymphonyElixir.GitHubProjects.Delivery.Client do
  @moduledoc "Fixed GET operations with scoped credentials, bounded bodies and complete pagination."

  alias SymphonyElixir.GitHub.Credentials
  alias SymphonyElixir.GitHubProjects.Delivery.{JSON, Settings}

  @api "https://api.github.com"
  @max_body 5_242_880

  @spec new(map(), keyword()) :: map()
  def new(settings, opts \\ []) do
    now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    %{settings: settings, opts: opts, now: now, deadline: now.() + Keyword.get(opts, :deadline_ms, 300_000)}
  end

  @spec fetch(map(), atom(), list()) :: {:ok, term()} | {:error, term()}
  def fetch(client, operation, args \\ []) do
    with {:ok, path, params} <- route(client, operation, args),
         {:ok, response} <- api(client, path, params) do
      JSON.decode(response.body, @max_body)
    end
  end

  @spec list(map(), atom(), list()) :: {:ok, [map()]} | {:error, term()}
  def list(client, operation, args \\ []) do
    with {:ok, path, params} <- route(client, operation, args) do
      pages(client, path, params, collection(operation), 1, [], nil)
    end
  end

  @spec content(map(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def content(client, path, sha) do
    with {:ok, %{"type" => "file", "path" => ^path, "encoding" => "base64", "content" => encoded}} <- fetch(client, :content, [path, sha]),
         true <- is_binary(encoded),
         {:ok, bytes} <- Base.decode64(String.replace(encoded, "\n", "")) do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :content_unavailable}
    end
  end

  @spec download(map(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def download(client, artifact_id) do
    with true <- Settings.id?(artifact_id),
         {:ok, response} <- api(client, "/actions/artifacts/#{artifact_id}/zip", %{}, 302),
         [url] <- header(response, "location"),
         true <- storage_url?(url),
         {:ok, %{status: 200, body: body}} <- request(client, url, [], %{}) do
      {:ok, body}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :artifact_download_invalid}
    end
  end

  @spec storage_url?(term()) :: boolean()
  def storage_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil} when is_binary(host) ->
        Regex.match?(~r/\Aproductionresults[a-z0-9]+\.blob\.core\.windows\.net\z/, host)

      _ ->
        false
    end
  end

  def storage_url?(_), do: false

  defp pages(client, path, params, key, page, acc, count) do
    if page > Keyword.get(client.opts, :max_pages, 100) do
      {:error, :observation_page_limit}
    else
      with {:ok, response} <- api(client, path, Map.merge(params, %{per_page: 100, page: page})),
           {:ok, decoded} <- JSON.decode(response.body, @max_body),
           {:ok, entries, total} <- entries(decoded, key),
           true <- is_nil(count) or count == total,
           true <- Enum.all?(entries, &(is_map(&1) and Settings.id?(&1["id"]))),
           combined = acc ++ entries,
           true <- length(Enum.uniq_by(combined, & &1["id"])) == length(combined) do
        next_page(client, path, params, key, page, combined, entries, total)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :observation_pages_changed}
      end
    end
  end

  defp next_page(client, path, params, key, page, all, entries, total) do
    over_count = is_integer(total) and length(all) > total

    cond do
      length(entries) > 100 -> {:error, :invalid_collection}
      over_count -> {:error, :observation_pages_changed}
      length(all) == total -> {:ok, all}
      length(entries) < 100 and not is_nil(total) -> {:error, :observation_incomplete}
      length(entries) < 100 -> {:ok, all}
      true -> pages(client, path, params, key, page + 1, all, total)
    end
  end

  defp entries(body, nil) when is_list(body), do: {:ok, body, nil}

  defp entries(body, key) when is_map(body) do
    if is_list(body[key]) and is_integer(body["total_count"]) and body["total_count"] >= 0 do
      {:ok, body[key], body["total_count"]}
    else
      {:error, :invalid_collection}
    end
  end

  defp entries(_, _), do: {:error, :invalid_collection}

  defp collection(:runs), do: "workflow_runs"
  defp collection(:jobs), do: "jobs"
  defp collection(:artifacts), do: "artifacts"
  defp collection(_), do: nil

  defp route(_, :repo, []), do: {:ok, "", %{}}
  defp route(_, :ref, []), do: {:ok, "/git/ref/heads/dev", %{}}
  defp route(_, :pulls, []), do: {:ok, "/pulls", %{state: "open", base: "dev"}}
  defp route(_, :pull, [id]) when is_integer(id) and id > 0, do: {:ok, "/pulls/#{id}", %{}}
  defp route(_, :run, [id]) when is_integer(id) and id > 0, do: {:ok, "/actions/runs/#{id}", %{}}
  defp route(_, :artifacts, [id]) when is_integer(id) and id > 0, do: {:ok, "/actions/runs/#{id}/artifacts", %{}}
  defp route(_, :runs, [id]) when is_integer(id) and id > 0, do: {:ok, "/actions/workflows/#{id}/runs", %{}}

  defp route(_, :jobs, [id, attempt]) when is_integer(id) and id > 0 and is_integer(attempt) and attempt > 0,
    do: {:ok, "/actions/runs/#{id}/attempts/#{attempt}/jobs", %{}}

  defp route(client, :workflow, [path]) do
    if path in Settings.paths(client.settings.policy),
      do: {:ok, "/actions/workflows/" <> URI.encode_www_form(Path.basename(path)), %{}},
      else: {:error, :invalid_delivery_operation}
  end

  defp route(client, :content, [path, sha]) do
    if path in Settings.paths(client.settings.policy) and Settings.sha?(sha), do: {:ok, "/contents/" <> path, %{ref: sha}}, else: {:error, :invalid_delivery_operation}
  end

  defp route(_, :compare, [base, head]) do
    if Settings.sha?(base) and Settings.sha?(head), do: {:ok, "/compare/#{base}...#{head}", %{per_page: 1}}, else: {:error, :invalid_delivery_operation}
  end

  defp route(_, :commit, [sha]) do
    if Settings.sha?(sha), do: {:ok, "/git/commits/#{sha}", %{}}, else: {:error, :invalid_delivery_operation}
  end

  defp route(_, _, _), do: {:error, :invalid_delivery_operation}

  defp api(client, path, params, expected \\ 200) do
    reference = client.settings.reference

    with {:ok, token} <- Credentials.token(reference, client.opts),
         {:ok, response} <- request(client, @api <> "/repos/" <> reference.repo <> path, auth(token), params) do
      cond do
        response.status == expected ->
          {:ok, response}

        response.status == 401 ->
          Credentials.invalidate(reference, token, client.opts)
          {:error, :github_delivery_unauthorized}

        limited?(response) ->
          {:error, {:github_delivery_limited, retry_after(response)}}

        true ->
          {:error, {:github_delivery_http, response.status}}
      end
    end
  end

  defp limited?(response) do
    response.status == 429 or
      (response.status == 403 and (header(response, "retry-after") != [] or header(response, "x-ratelimit-remaining") == ["0"]))
  end

  defp request(client, url, headers, params, remaining_retry \\ 1) do
    left = client.deadline - client.now.()

    if left <= 0 do
      {:error, :observation_deadline}
    else
      response = send_request(client, url, headers, params, min(left, 30_000))

      if remaining_retry > 0 and transient?(response) do
        request(client, url, headers, params, remaining_retry - 1)
      else
        bounded_response(response)
      end
    end
  end

  defp send_request(client, url, headers, params, timeout) do
    opts = [
      method: :get,
      url: url,
      headers: headers,
      params: params,
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      into: &collect/2
    ]

    opts = if client.opts[:req_adapter], do: Keyword.put(opts, :adapter, client.opts[:req_adapter]), else: opts
    Keyword.get(client.opts, :http, &Req.request/1).(opts)
  rescue
    _ -> {:error, :github_delivery_transport}
  catch
    _, _ -> {:error, :github_delivery_transport}
  end

  defp collect({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) <= @max_body do
      {:cont, {request, %{response | body: body}}}
    else
      {:halt, {request, %{response | body: :too_large}}}
    end
  end

  defp bounded_response({:ok, %{body: body} = response}) when is_binary(body) and byte_size(body) <= @max_body, do: {:ok, response}
  defp bounded_response(_), do: {:error, :github_delivery_response_unavailable}
  defp transient?({:error, _}), do: true
  defp transient?({:ok, %{status: status}}), do: status in [502, 503, 504]
  defp transient?(_), do: false
  defp header(response, key), do: Map.get(Map.get(response, :headers, %{}), key, [])

  defp retry_after(response) do
    delay = header(response, "retry-after") |> List.first() |> parse_seconds()
    reset = header(response, "x-ratelimit-reset") |> List.first() |> parse_seconds()
    max(delay, reset - System.system_time(:second))
  end

  defp parse_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> 60
    end
  end

  defp parse_seconds(_), do: 60
  defp auth(token), do: [{"authorization", "Bearer " <> token}, {"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
end
