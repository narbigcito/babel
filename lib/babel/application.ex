defmodule Babel.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Babel.Finch, pools: %{:default => [size: 20, count: 4]}},
      {Phoenix.PubSub, name: Babel.PubSub},
      Babel.ConfigLoader,
      Babel.Stats,
      BabelWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Babel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BabelWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
