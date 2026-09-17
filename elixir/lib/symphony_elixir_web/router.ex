defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :operator_access do
    plug(SymphonyElixirWeb.OperatorAuth, :access)
  end

  pipeline :operator_login do
    plug(SymphonyElixirWeb.OperatorAuth, :login)
  end

  pipeline :operator_api do
    plug(:fetch_session)
    plug(SymphonyElixirWeb.OperatorAuth, :api)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :operator_access])

    live_session :dashboard, on_mount: SymphonyElixirWeb.OperatorAuth do
      live("/", DashboardLive, :index)
    end
  end

  scope "/operator", SymphonyElixirWeb do
    pipe_through([:browser, :operator_login])
    get("/login", OperatorSessionController, :index)
    post("/login", OperatorSessionController, :create)
    post("/logout", OperatorSessionController, :delete)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:operator_api)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
