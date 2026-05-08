defmodule BabelWeb.Router do
  use BabelWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BabelWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_auth do
    plug BabelWeb.Plugs.RequireAuth
  end

  # Login / logout — no auth required
  scope "/", BabelWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  # UI — requires auth when BABEL_UI_PASSWORD is set
  scope "/", BabelWeb do
    pipe_through [:browser, :require_auth]

    live "/", DashboardLive
    live "/dashboard", DashboardLive
    live "/providers", ProvidersLive
    live "/chat", ChatLive
    live "/users", UsersLive
  end

  # Proxy API — no auth (uses its own api_key check in the controller)
  scope "/", BabelWeb do
    pipe_through :api

    get "/health", ApiController, :health
    get "/v1/models", ApiController, :list_models
    post "/v1/chat/completions", ApiController, :chat_completions
  end
end
