defmodule SymphonyElixirWeb.OperatorSessionController do
  @moduledoc "Local operator sign-in and session revocation. Credentials never appear in rendered output."
  use Phoenix.Controller, formats: [:html]
  alias Plug.Conn
  alias SymphonyElixir.Operator.Auth
  alias SymphonyElixirWeb.OperatorAuth

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _), do: render_login(conn, "")

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    case Auth.login(OperatorAuth.server(), params["credential"]) do
      {:ok, session} ->
        Plug.CSRFProtection.delete_csrf_token()

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:operator_session, session)
        |> put_session(:live_socket_id, "operator:" <> session)
        |> redirect(to: "/")

      {:error, :login_rate_limited} ->
        conn |> put_status(429) |> render_login("Слишком много попыток. Повторите через минуту.")

      _ ->
        conn |> put_status(401) |> render_login("Вход не выполнен. Проверьте локальный секрет оператора.")
    end
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _) do
    Auth.logout(OperatorAuth.server(), get_session(conn, :operator_session))
    conn |> configure_session(drop: true) |> redirect(to: "/operator/login")
  end

  defp render_login(conn, message) do
    csrf = Plug.CSRFProtection.get_csrf_token() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> html("""
    <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Вход оператора · Symphony</title><link rel="stylesheet" href="/dashboard.css"></head>
    <body><main class="dashboard-shell"><section class="section-card"><p class="eyebrow">Symphony</p><h1>Вход оператора</h1>
    <p>Введите секрет из локального файла controller. Это отдельный доступ к панели.</p><p role="alert">#{message}</p>
    <form method="post" action="/operator/login"><input type="hidden" name="_csrf_token" value="#{csrf}">
    <label for="credential">Секрет оператора</label><input id="credential" name="credential" type="password" autocomplete="current-password" required maxlength="128">
    <button type="submit">Войти</button></form></section></main></body></html>
    """)
  end
end
