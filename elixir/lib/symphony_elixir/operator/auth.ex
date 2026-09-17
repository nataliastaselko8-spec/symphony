defmodule SymphonyElixir.Operator.Auth do
  @moduledoc "Single local principal, revocable sessions and bounded version-bound forms. Never owns delivery state."
  use GenServer

  alias SymphonyElixir.Operator.Credential
  @idle_ms 1_800_000
  @lifetime_ms 28_800_000
  @form_ms 1_800_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec settings(map()) :: {:ok, map() | nil} | {:error, atom()}
  def settings(%{operator: operator}) when operator == %{}, do: {:ok, nil}

  def settings(%{operator: %{"principal" => principal, "credential_path" => path} = operator, host: host, port: port}) do
    if map_size(operator) == 2 and is_binary(principal) and Regex.match?(~r/\Alocal:[a-zA-Z0-9_-]{1,64}\z/, principal) and
         is_binary(path) and host in ["127.0.0.1", "localhost", "::1"] and is_integer(port) and port in 1..65_535 do
      url_host = if host == "::1", do: "[::1]", else: host
      {:ok, %{principal: principal, credential_path: path, origin: "http://#{url_host}:#{port}"}}
    else
      {:error, :invalid_operator_settings}
    end
  end

  def settings(_), do: {:error, :invalid_operator_settings}

  @spec from_config(SymphonyElixir.Config.Schema.t()) :: {:ok, map() | nil} | {:error, atom()}
  def from_config(config) do
    with {:ok, settings} <- settings(config.server) do
      root = Path.expand(config.workspace.root)
      path = settings && settings.credential_path
      prefix = String.trim_trailing(root, "/") <> "/"
      inside? = is_binary(path) and (path == root or String.starts_with?(path, prefix))

      if inside?,
        do: {:error, :operator_credential_inside_workspace},
        else: {:ok, settings}
    end
  end

  @spec login(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def login(server, secret), do: call(server, {:login, secret})

  @spec check(GenServer.server(), term(), boolean()) :: {:ok, String.t()} | {:error, atom()}
  def check(server, session, touch \\ false), do: call(server, {:check, session, touch})

  @spec logout(GenServer.server(), term()) :: :ok | {:error, atom()}
  def logout(server, session), do: call(server, {:logout, session})

  @spec prepare(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(server, session, form), do: call(server, {:prepare, session, form})

  @spec form(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def form(server, session, id), do: call(server, {:form, session, id})

  @spec info(GenServer.server()) :: {:ok, map() | nil} | {:error, atom()}
  def info(server), do: call(server, :info)

  @spec revoke(GenServer.server()) :: :ok | {:error, atom()}
  def revoke(server), do: call(server, :revoke)

  @spec allow_read(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def allow_read(server, session), do: call(server, {:allow_read, session})

  @impl true
  def init(opts) do
    settings = Keyword.get(opts, :settings)

    case if(settings, do: Credential.read(settings.credential_path), else: {:ok, nil}) do
      {:ok, hash} -> {:ok, %{settings: settings, hash: hash, now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end), sessions: %{}, forms: %{}, attempts: []}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _, state), do: {:reply, {:ok, state.settings && Map.take(state.settings, [:principal, :origin])}, state}

  def handle_call({:login, _}, _, %{settings: nil} = state), do: {:reply, {:error, :operator_disabled}, state}

  def handle_call({:login, secret}, _, state) do
    state = prune(state)
    attempts = Enum.filter(state.attempts, &(state.now.() - &1 < 60_000))

    cond do
      length(attempts) >= 5 ->
        {:reply, {:error, :login_rate_limited}, %{state | attempts: attempts}}

      not valid_secret?(state, secret) ->
        {:reply, {:error, :invalid_login}, %{state | attempts: [state.now.() | attempts]}}

      map_size(state.sessions) >= 8 ->
        {:reply, {:error, :session_limit}, state}

      true ->
        token = token()
        session = %{created: state.now.(), touched: state.now.(), reads: []}
        {:reply, {:ok, token}, put_in(state, [:sessions, token], session)}
    end
  end

  def handle_call({:check, token, touch}, _, state) do
    state = prune(state)

    if Map.has_key?(state.sessions, token) do
      next = if touch, do: put_in(state, [:sessions, token, :touched], state.now.()), else: state
      {:reply, {:ok, state.settings.principal}, next}
    else
      {:reply, {:error, :operator_login_required}, state}
    end
  end

  def handle_call({:logout, token}, _, state) do
    disconnect(token)
    {:reply, :ok, prune(%{state | sessions: Map.delete(state.sessions, token)})}
  end

  def handle_call(:revoke, _, state) do
    Enum.each(Map.keys(state.sessions), &disconnect/1)
    {:reply, :ok, %{state | sessions: %{}, forms: %{}}}
  end

  def handle_call({:prepare, session, form}, _, state) do
    state = prune(state)

    if Map.has_key?(state.sessions, session) and Enum.count(state.forms, fn {_, f} -> f.session == session end) < 20 do
      id = token()
      form = Map.merge(form, %{id: id, session: session, actor: state.settings.principal, expires: state.now.() + @form_ms})
      {:reply, {:ok, form}, put_in(state, [:forms, id], form)}
    else
      {:reply, {:error, :operator_form_unavailable}, state}
    end
  end

  def handle_call({:form, session, id}, _, state) do
    state = prune(state)

    result =
      case state.forms[id] do
        %{session: ^session} = form -> {:ok, form}
        _ -> {:error, :operator_form_expired}
      end

    {:reply, result, state}
  end

  def handle_call({:allow_read, token}, _, state) do
    state = prune(state)

    case state.sessions[token] do
      nil ->
        {:reply, {:error, :operator_login_required}, state}

      session ->
        reads = Enum.filter(session.reads, &(state.now.() - &1 < 60_000))

        if length(reads) < 10,
          do: {:reply, :ok, put_in(state, [:sessions, token, :reads], [state.now.() | reads])},
          else: {:reply, {:error, :operator_read_rate_limited}, state}
    end
  end

  @impl true
  def format_status(_), do: %{state: :operator_credentials_redacted}

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :operator_auth_unavailable}
  end

  defp valid_secret?(state, secret) when is_binary(secret) and byte_size(secret) <= 128,
    do: Plug.Crypto.secure_compare(state.hash, :crypto.hash(:sha256, secret))

  defp valid_secret?(_, _), do: false

  defp prune(state) do
    {live, expired} = Enum.split_with(state.sessions, fn {_, s} -> state.now.() - s.created < @lifetime_ms and state.now.() - s.touched < @idle_ms end)
    Enum.each(expired, fn {id, _} -> disconnect(id) end)
    sessions = Map.new(live)
    forms = Map.reject(state.forms, fn {_, f} -> f.expires <= state.now.() or not Map.has_key?(sessions, f.session) end)
    %{state | sessions: sessions, forms: forms}
  end

  defp disconnect(token) when is_binary(token) do
    message = %Phoenix.Socket.Broadcast{topic: "operator:" <> token, event: "disconnect", payload: %{}}
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, message.topic, message)
  end

  defp disconnect(_), do: :ok
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
