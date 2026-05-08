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

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def reload, do: GenServer.call(__MODULE__, :reload)

  def upsert_provider(name, attrs) do
    GenServer.call(__MODULE__, {:upsert_provider, name, attrs})
  end

  def delete_provider(name) do
    GenServer.call(__MODULE__, {:delete_provider, name})
  end

  @impl true
  def init(_), do: {:ok, load_config()}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:reload, _from, _state) do
    new = load_config()
    {:reply, new, new}
  end

  @impl true
  def handle_call({:upsert_provider, name, attrs}, _from, state) do
    provider = %Provider{
      name: name,
      base_url: String.trim(attrs["base_url"] || ""),
      api_key: String.trim(attrs["api_key"] || ""),
      default_headers: parse_headers(attrs["default_headers"] || "")
    }

    new_state = %{state | providers: Map.put(state.providers, name, provider)}

    case write_config(new_state) do
      :ok ->
        broadcast(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_provider, name}, _from, state) do
    new_state = %{state | providers: Map.delete(state.providers, name)}

    case write_config(new_state) do
      :ok ->
        broadcast(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- config loading ---

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
          data || %{}

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

  # --- YAML serialization ---

  defp write_config(config) do
    path = config_path()

    try do
      File.write!(path, to_yaml(config))
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp to_yaml(%__MODULE__{} = c) do
    [
      api_key_yaml(c.api_key),
      providers_yaml(c.providers),
      models_yaml(c.models),
      "server:\n  host: #{c.host}\n  port: #{c.port}\n"
    ]
    |> Enum.join("\n")
  end

  defp api_key_yaml(nil), do: "# api_key: your-secret-key\n"
  defp api_key_yaml(k), do: "api_key: #{k}\n"

  defp providers_yaml(providers) when map_size(providers) == 0, do: "providers: {}\n"

  defp providers_yaml(providers) do
    entries =
      Enum.map(providers, fn {name, p} ->
        headers =
          if map_size(p.default_headers) > 0 do
            lines = Enum.map(p.default_headers, fn {k, v} -> "      #{k}: #{v}" end)
            "    default_headers:\n" <> Enum.join(lines, "\n") <> "\n"
          else
            "    default_headers: {}\n"
          end

        "  #{name}:\n    base_url: #{p.base_url}\n    api_key: #{p.api_key}\n#{headers}"
      end)

    "providers:\n" <> Enum.join(entries, "")
  end

  defp models_yaml(models) when map_size(models) == 0, do: "models: {}\n"

  defp models_yaml(models) do
    entries =
      Enum.map(models, fn {name, m} ->
        base = if m.base_url, do: "    base_url: #{m.base_url}\n", else: ""

        extra =
          if map_size(m.extra_headers) > 0 do
            lines = Enum.map(m.extra_headers, fn {k, v} -> "      #{k}: #{v}" end)
            "    extra_headers:\n" <> Enum.join(lines, "\n") <> "\n"
          else
            ""
          end

        "  #{name}:\n    provider: #{m.provider}\n#{base}#{extra}"
      end)

    "models:\n" <> Enum.join(entries, "")
  end

  # --- helpers ---

  defp parse_headers(""), do: %{}
  defp parse_headers(nil), do: %{}

  defp parse_headers(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> stringify_keys(map)
      _ -> %{}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify_keys(_), do: %{}

  defp broadcast(config) do
    Phoenix.PubSub.broadcast(Babel.PubSub, "babel:config", {:config_updated, config})
  end
end
