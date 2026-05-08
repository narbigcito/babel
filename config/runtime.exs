import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      "prodbabelgatewaysecretkey64charsminimumforPhoenixproductionuse!!"

  config :babel, BabelWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: 8787],
    secret_key_base: secret_key_base,
    check_origin: false,
    server: true
end
