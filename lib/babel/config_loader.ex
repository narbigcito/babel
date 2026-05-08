defmodule Babel.ConfigLoader do
  use GenServer
  require Logger

  defmodule Provider do
    defstruct name: "", base_url: "", api_key: "", default_headers: %{}
  end

  defmodule Model do
    defstruct name: "", provider: "", base_url: nil, extra_headers: %{}
  end

  defmodule Preset do
    defstruct name: "", provider: "", model: "", system_prompt: "",
              temperature: nil, max_tokens: nil, thinking_enabled: false, thinking_budget: 10000
  end

  defmodule User do
    defstruct username: "", password_hash: ""
  end

  defstruct providers: %{}, models: %{}, presets: %{}, users: %{},
            host: "0.0.0.0", port: 8787, api_key: nil

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def reload, do: GenServer.call(__MODULE__, :reload)

  def upsert_provider(name, attrs) do
    GenServer.call(__MODULE__, {:upsert_provider, name, attrs})
  end

  def delete_provider(name) do
    GenServer.call(__MODULE__, {:delete_provider, name})
  end

  def sync_provider_models(provider_name, model_ids) do
    GenServer.call(__MODULE__, {:sync_provider_models, provider_name, model_ids})
  end

  def upsert_preset(name, attrs) do
    GenServer.call(__MODULE__, {:upsert_preset, name, attrs})
  end

  def delete_preset(name) do
    GenServer.call(__MODULE__, {:delete_preset, name})
  end

  def upsert_user(username, attrs) do
    GenServer.call(__MODULE__, {:upsert_user, username, attrs})
  end

  def delete_user(username) do
    GenServer.call(__MODULE__, {:delete_user, username})
  end

  def authenticate_user(username, password) do
    config = get()

    cond do
      map_size(config.users) > 0 ->
        user = config.users[username]
        user && user.password_hash == hash_password(password)

      true ->
        env = System.get_env("BABEL_UI_PASSWORD")
        is_binary(env) and env != "" and password == env
    end
  end

  def auth_mode do
    config = get()
    cond do
      map_size(config.users) > 0 -> :users
      System.get_env("BABEL_UI_PASSWORD") not in [nil, ""] -> :password
      true -> :none
    end
  end

  def hash_password(password) do
    salt = Application.get_env(:babel, BabelWeb.Endpoint)[:secret_key_base]
           |> binary_part(0, 32)
    :crypto.hash(:sha256, salt <> password) |> Base.encode16(case: :lower)
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
  def handle_call({:sync_provider_models, provider_name, model_ids}, _from, state) do
    kept = state.models |> Enum.reject(fn {_, m} -> m.provider == provider_name end) |> Map.new()

    synced =
      model_ids
      |> Enum.map(fn id -> {id, %Model{name: id, provider: provider_name}} end)
      |> Map.new()

    new_state = %{state | models: Map.merge(kept, synced)}

    case write_config(new_state) do
      :ok ->
        broadcast(new_state)
        {:reply, {:ok, map_size(synced)}, new_state}

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

  @impl true
  def handle_call({:upsert_preset, name, attrs}, _from, state) do
    preset = %Preset{
      name: name,
      provider: attrs["provider"] || "",
      model: attrs["model"] || "",
      system_prompt: String.trim(attrs["system_prompt"] || ""),
      temperature: parse_optional_float(attrs["temperature"]),
      max_tokens: parse_optional_int(attrs["max_tokens"]),
      thinking_enabled: attrs["thinking_enabled"] == true or attrs["thinking_enabled"] == "true",
      thinking_budget: parse_optional_int(attrs["thinking_budget"]) || 10000
    }

    new_state = %{state | presets: Map.put(state.presets, name, preset)}

    case write_config(new_state) do
      :ok ->
        broadcast(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_preset, name}, _from, state) do
    new_state = %{state | presets: Map.delete(state.presets, name)}

    case write_config(new_state) do
      :ok ->
        broadcast(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:upsert_user, username, attrs}, _from, state) do
    existing = state.users[username]

    password_hash =
      case attrs["password"] do
        p when is_binary(p) and p != "" -> hash_password(p)
        _ -> if existing, do: existing.password_hash, else: ""
      end

    user = %User{username: username, password_hash: password_hash}
    new_state = %{state | users: Map.put(state.users, username, user)}

    case write_config(new_state) do
      :ok ->
        broadcast(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_user, username}, _from, state) do
    new_state = %{state | users: Map.delete(state.users, username)}

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

    presets =
      data
      |> Map.get("presets", %{})
      |> Enum.map(fn {name, p} ->
        {name,
         %Preset{
           name: name,
           provider: p["provider"] || "",
           model: p["model"] || "",
           system_prompt: p["system_prompt"] || "",
           temperature: p["temperature"],
           max_tokens: p["max_tokens"],
           thinking_enabled: p["thinking_enabled"] || false,
           thinking_budget: p["thinking_budget"] || 10000
         }}
      end)
      |> Map.new()

    users =
      data
      |> Map.get("users", %{})
      |> Enum.map(fn {username, u} ->
        {username, %User{username: username, password_hash: u["password_hash"] || ""}}
      end)
      |> Map.new()

    server = data["server"] || %{}

    %__MODULE__{
      providers: providers,
      models: models,
      presets: presets,
      users: users,
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
      presets_yaml(c.presets),
      users_yaml(c.users),
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

  defp presets_yaml(presets) when map_size(presets) == 0, do: "presets: {}\n"

  defp presets_yaml(presets) do
    entries =
      Enum.map(presets, fn {name, p} ->
        sys =
          if p.system_prompt != "",
            do: "    system_prompt: #{Jason.encode!(p.system_prompt)}\n",
            else: ""

        temp = if p.temperature != nil, do: "    temperature: #{p.temperature}\n", else: ""
        max_tok = if p.max_tokens != nil, do: "    max_tokens: #{p.max_tokens}\n", else: ""

        thinking =
          "    thinking_enabled: #{p.thinking_enabled}\n    thinking_budget: #{p.thinking_budget}\n"

        "  #{name}:\n    provider: #{p.provider}\n    model: #{p.model}\n#{sys}#{temp}#{max_tok}#{thinking}"
      end)

    "presets:\n" <> Enum.join(entries, "")
  end

  defp users_yaml(users) when map_size(users) == 0, do: "users: {}\n"

  defp users_yaml(users) do
    entries =
      Enum.map(users, fn {username, u} ->
        "  #{username}:\n    password_hash: #{u.password_hash}\n"
      end)

    "users:\n" <> Enum.join(entries, "")
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

  defp parse_optional_float(nil), do: nil
  defp parse_optional_float(""), do: nil

  defp parse_optional_float(v) when is_float(v), do: v
  defp parse_optional_float(v) when is_integer(v), do: v / 1

  defp parse_optional_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil
  defp parse_optional_int(v) when is_integer(v) and v > 0, do: v

  defp parse_optional_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} when i > 0 -> i
      _ -> nil
    end
  end

  defp parse_optional_int(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify_keys(_), do: %{}

  defp broadcast(config) do
    Phoenix.PubSub.broadcast(Babel.PubSub, "babel:config", {:config_updated, config})
  end
end
