defmodule SymphonyElixir.GitHub.Credentials.Issuer do
  @moduledoc false

  import Bitwise
  alias SymphonyElixir.GitHub.Credentials.Reference

  @endpoint "https://api.github.com"
  @api_version "2026-03-10"

  @spec issue(Reference.t(), integer(), keyword()) :: {:ok, String.t(), integer()} | {:error, term()}
  def issue(%Reference{} = reference, now, opts) do
    with {:ok, jwt} <- jwt(reference, now),
         {:ok, installation} <- request("GET", installation_path(reference), nil, jwt, opts),
         :ok <- validate_installation(installation, reference),
         {:ok, response} <- request("POST", installation_path(reference) <> "/access_tokens", token_body(reference), jwt, opts) do
      validate_token(response, reference, now)
    end
  rescue
    _error -> {:error, :github_credential_issue_failed}
  catch
    _kind, _reason -> {:error, :github_credential_issue_failed}
  end

  defp jwt(reference, now) do
    with {:ok, pem} <- read_key(reference.private_key_path),
         {:ok, key} <- decode_key(pem) do
      header = encode(%{"alg" => "RS256", "typ" => "JWT"})
      payload = encode(%{"iat" => now - 60, "exp" => now + 540, "iss" => reference.client_id || reference.app_id})
      signed = header <> "." <> payload
      signature = :public_key.sign(signed, :sha256, key)
      {:ok, signed <> "." <> Base.url_encode64(signature, padding: false)}
    end
  end

  defp read_key(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and band(stat.mode, 0o777) in [0o400, 0o600],
         true <- stat.size > 0 and stat.size <= 65_536,
         {:ok, pem} <- File.read(path) do
      {:ok, pem}
    else
      _error -> {:error, :github_app_key_unavailable}
    end
  end

  defp decode_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry] ->
        entry |> :public_key.pem_entry_decode() |> validate_key()

      _entries ->
        {:error, :github_app_key_invalid}
    end
  rescue
    _error -> {:error, :github_app_key_invalid}
  end

  defp validate_key(key) when is_tuple(key) and elem(key, 0) == :RSAPrivateKey and tuple_size(key) >= 3 do
    if elem(key, 2) >= 1 <<< 2047,
      do: {:ok, key},
      else: {:error, :github_app_key_invalid}
  end

  defp validate_key(_key), do: {:error, :github_app_key_invalid}

  defp request(method, path, body, jwt, opts) do
    request_fun =
      Keyword.get(opts, :request_fun, fn method, path, body, jwt ->
        perform_request(method, path, body, jwt, Keyword.get(opts, :req_adapter))
      end)

    case request_fun.(method, path, body, jwt) do
      {:ok, %{status: status, body: %{} = body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:github_credential_http, status}}

      _response ->
        {:error, :github_credential_request_failed}
    end
  end

  defp perform_request(method, path, body, jwt, adapter) do
    request = if is_nil(adapter), do: Req.new(), else: Req.new(adapter: adapter)

    opts = [
      method: if(method == "GET", do: :get, else: :post),
      url: @endpoint <> path,
      headers: [
        {"authorization", "Bearer " <> jwt},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", @api_version},
        {"user-agent", "symphony"}
      ],
      redirect: false,
      retry: false,
      connect_options: [timeout: 10_000],
      receive_timeout: 15_000
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    case Req.request(request, opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :request_failed}
    end
  end

  defp validate_installation(installation, reference) do
    account = installation["account"]
    owner = reference.repo |> String.split("/") |> hd()

    cond do
      installation["app_id"] != String.to_integer(reference.app_id) ->
        {:error, :github_installation_identity_mismatch}

      installation["id"] != String.to_integer(reference.installation_id) ->
        {:error, :github_installation_identity_mismatch}

      not valid_account?(account, owner, reference.profile) ->
        {:error, :github_installation_identity_mismatch}

      not is_nil(installation["suspended_at"]) ->
        {:error, :github_installation_suspended}

      true ->
        :ok
    end
  end

  defp valid_account?(%{"login" => login, "type" => type}, owner, profile) when is_binary(login) do
    String.downcase(login) == String.downcase(owner) and
      type in ["User", "Organization"] and
      (profile not in [:projects_read, :projects_write] or type == "Organization")
  end

  defp valid_account?(_account, _owner, _profile), do: false

  defp validate_token(response, reference, now) do
    with true <- is_binary(response["token"]) and String.trim(response["token"]) != "",
         true <- response["permissions"] == reference.permissions,
         true <- valid_repositories?(response, reference.repo),
         {:ok, expires, _offset} <- DateTime.from_iso8601(response["expires_at"]),
         expiry = DateTime.to_unix(expires),
         true <- expiry > now + 60 and expiry <= now + 3_660 do
      {:ok, response["token"], expiry}
    else
      _error -> {:error, :github_installation_token_invalid}
    end
  end

  defp valid_repositories?(%{"repositories" => [repo], "repository_selection" => "selected"}, expected)
       when is_map(repo) do
    is_integer(repo["id"]) and repo["id"] > 0 and is_binary(repo["full_name"]) and
      String.downcase(repo["full_name"]) == String.downcase(expected)
  end

  defp valid_repositories?(_response, _expected), do: false

  defp token_body(reference) do
    %{"repositories" => [reference.repo |> String.split("/") |> List.last()], "permissions" => reference.permissions}
  end

  defp installation_path(reference), do: "/app/installations/" <> reference.installation_id
  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end
