defmodule SymphonyElixir.GitHub.Credentials.Cache do
  @moduledoc """
  Controller-local installation tokens, serialized refresh and conditional invalidation.

  Tokens are never persisted. A failed refresh briefly caches only a safe error so
  concurrent callers cannot create an authentication retry storm.
  """

  use GenServer

  alias SymphonyElixir.GitHub.Credentials.Cache.Token
  alias SymphonyElixir.GitHub.Credentials.{Issuer, Reference}

  @refresh_margin 60
  @failure_backoff 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{entries: %{}, opts: Keyword.take(opts, [:request_fun, :req_adapter]), now_fun: Keyword.get(opts, :now_fun, fn -> System.system_time(:second) end)}}
  end

  @impl true
  def handle_call({:token, %Reference{} = reference}, _from, state) do
    read_token(reference, state)
  rescue
    _error -> {:reply, {:error, :github_credentials_unavailable}, %{state | entries: %{}}}
  catch
    _kind, _reason -> {:reply, {:error, :github_credentials_unavailable}, %{state | entries: %{}}}
  end

  @impl true
  def handle_call({:invalidate, %Reference{} = reference, token}, _from, state) when is_binary(token) do
    entries =
      case Map.get(state.entries, reference) do
        %{token: ^token} -> Map.delete(state.entries, reference)
        _entry -> state.entries
      end

    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_call(_message, _from, state), do: {:reply, {:error, :github_credential_request_invalid}, state}

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, %{cached_references: map_size(state.entries)}}
      {key, _value} -> {key, :redacted}
    end)
  end

  defp read_token(reference, state) do
    now = state.now_fun.()

    case Map.get(state.entries, reference) do
      %{token: token, expires_at: expires_at} when expires_at > now + @refresh_margin ->
        {:reply, {:ok, token}, state}

      %{error: reason, retry_at: retry_at} when retry_at > now ->
        {:reply, {:error, reason}, state}

      _entry ->
        refresh(reference, now, state)
    end
  end

  defp refresh(reference, now, state) do
    result = Issuer.issue(reference, now, state.opts)
    completed_at = state.now_fun.()
    store_result(result, reference, completed_at, state)
  end

  defp store_result({:ok, token, expires_at}, reference, now, state) when expires_at > now + @refresh_margin do
    entry = %Token{token: token, expires_at: expires_at}
    {:reply, {:ok, token}, %{state | entries: Map.put(state.entries, reference, entry)}}
  end

  defp store_result({:ok, _token, _expires_at}, reference, now, state),
    do: store_result({:error, :github_installation_token_invalid}, reference, now, state)

  defp store_result({:error, reason}, reference, now, state) do
    entry = %{error: reason, retry_at: now + @failure_backoff}
    {:reply, {:error, reason}, %{state | entries: Map.put(state.entries, reference, entry)}}
  end
end
