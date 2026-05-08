import Config

config :babel, BabelWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BabelWeb.ErrorHTML, json: BabelWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Babel.PubSub,
  live_view: [signing_salt: "babelgw2024salt"]

config :esbuild,
  version: "0.17.11",
  babel: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  babel: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

import_config "#{config_env()}.exs"
