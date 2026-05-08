import Config

config :babel, BabelWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 8787],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "devbabelsecretkeybasethatisatleast64charlongforPhoenixdevmode!!",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:babel, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:babel, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/babel_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, :console,
  format: "[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :debug_heex_annotations, true
