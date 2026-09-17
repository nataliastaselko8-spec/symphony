defmodule SymphonyElixirWeb.OperatorAuth do
  @moduledoc "HTTP and LiveView access checks for the configured local operator."
  import Plug.Conn
  alias SymphonyElixir.Operator.Auth
  alias SymphonyElixirWeb.Endpoint

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec server() :: GenServer.server()
  def server, do: Endpoint.config(:operator_auth) || Auth

  @spec call(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def call(conn, mode) do
    case Auth.info(server()) do
      {:ok, nil} -> if(Endpoint.config(:operator_enabled), do: reject(conn, 503), else: disabled(conn, mode))
      {:ok, settings} -> authorize(conn, mode, settings)
      _ -> if(Endpoint.config(:operator_enabled), do: reject(conn, 503), else: conn)
    end
  end

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) :: {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _, session, socket) do
    case live_session(session["operator_session"]) do
      :ok -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/operator/login")}
    end
  end

  @spec live_session(term()) :: :ok | {:error, atom()}
  def live_session(session) do
    case Auth.info(server()) do
      {:ok, nil} -> if(Endpoint.config(:operator_enabled), do: {:error, :operator_auth_unavailable}, else: :ok)
      {:ok, _} -> with {:ok, _} <- Auth.check(server(), session), do: :ok
      _ -> if(Endpoint.config(:operator_enabled), do: {:error, :operator_auth_unavailable}, else: :ok)
    end
  end

  defp authorize(conn, mode, settings) do
    cond do
      not endpoint_safe?() ->
        reject(conn, 503)

      not origin?(conn, settings.origin) ->
        reject(conn, 403)

      mode == :login ->
        conn

      true ->
        authenticated(conn, mode)
    end
  end

  defp authenticated(conn, mode) do
    case Auth.check(server(), get_session(conn, :operator_session)) do
      {:ok, actor} ->
        conn = assign(conn, :operator_actor, actor)
        if mode == :api, do: Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([])), else: conn

      _ ->
        if mode == :api, do: reject(conn, 401), else: conn |> Phoenix.Controller.redirect(to: "/operator/login") |> halt()
    end
  end

  defp disabled(conn, :login), do: reject(conn, 404)
  defp disabled(conn, _), do: conn

  defp endpoint_safe? do
    secret = Endpoint.config(:secret_key_base)
    is_binary(secret) and byte_size(secret) >= 64 and secret != String.duplicate("s", 64) and Endpoint.config(:check_origin) != false
  end

  defp origin?(conn, origin) do
    uri = URI.parse(origin)
    host_ok = conn.host == uri.host and conn.port == uri.port and Atom.to_string(conn.scheme) == uri.scheme
    supplied = get_req_header(conn, "origin")
    host_ok and (supplied == [origin] or (conn.method in ["GET", "HEAD"] and supplied == []))
  end

  defp reject(conn, code), do: conn |> put_resp_content_type("text/plain") |> send_resp(code, "Operator access rejected") |> halt()
end
