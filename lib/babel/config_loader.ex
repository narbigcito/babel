defmodule Babel.ConfigLoader do
  use GenServer
  require Logger

  defmodule Provider do
    defstruct name: "", base_url: "", api_key: "", default_headers: %{}
  end

  defmodule Model do
    defstruct name: "", provider: "", base_url: nil, extra_headers: %{}
  end

  defstruct providers: %{}, models: %{}, host: "0.0.0.0", port: 8787, api_key: nil

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get, do: GenServer.call(__MODULE__, :get)

  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(_) do
    {:ok, load_config()}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:reload, _from, _state) do
    new_state = load_config()
    {:reply, new_state, new_state}
  end

  defp config_path do
    System.get_env("BABEL_CONFIG") ||
      Path.join([System.user_home!(), ".babel", "config.yaml"])
  end

  defp load_config do
    path = config_path()

    data =
      case YamlElixir.read_from_file(path) do
        {:ok, data} ->
          Logger.info("Babel config loaded from #{path}")
          data

        {:error, reason} ->
          Logger.warning("Could not load config from #{path}: #{inspect(reason)}")
          %{}
      end

    providers =
      data
      |> Map.get("providers", %{})
      |> Enum.map(fn {name, p} ->
        {name,
         %Provider{
           name: name,
           base_url: String.trim_trailing(p["base_url"] || "", "/"),
           api_key: p["api_key"] || "",
           default_headers: stringify_keys(p["default_headers"] || %{})
         }}
      end)
      |> Map.new()

    models =
      data
      |> Map.get("models", %{})
      |> Enum.map(fn {name, m} ->
        {name,
         %Model{
           name: name,
           provider: m["provider"] || "",
           base_url: m["base_url"],
           extra_headers: stringify_keys(m["extra_headers"] || %{})
         }}
      end)
      |> Map.new()

    server = data["server"] || %{}

    %__MODULE__{
      providers: providers,
      models: models,
      host: server["host"] || "0.0.0.0",
      port: server["port"] || 8787,
      api_key: data["api_key"]
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify_keys(_), do: %{}
end
