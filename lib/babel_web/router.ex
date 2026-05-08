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

  scope "/", BabelWeb do
    pipe_through :browser
    live "/", DashboardLive
    live "/dashboard", DashboardLive
    live "/providers", ProvidersLive
  end

  scope "/", BabelWeb do
    pipe_through :api
    get "/health", ApiController, :health
    get "/v1/models", ApiController, :list_models
    post "/v1/chat/completions", ApiController, :chat_completions
  end
end
