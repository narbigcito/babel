defmodule BabelWeb.ApiController do
  use BabelWeb, :controller
  require Logger

  alias Babel.ConfigLoader
  alias Babel.ConfigLoader.{Provider, Model}

  # --- /health ---

  def health(conn, _params) do
    config = ConfigLoader.get()

    json(conn, %{
      status: "healthy",
      gateway: "babel",
      version: "0.1.0",
      providers: Map.keys(config.providers),
      models: Map.keys(config.models)
    })
  end

  # --- /v1/models ---

  def list_models(conn, _params) do
    with :ok <- check_api_key(conn) do
      config = ConfigLoader.get()

      models =
        Enum.map(config.models, fn {name, %Model{provider: provider}} ->
          %{id: name, object: "model", created: 1_700_000_000, owned_by: provider}
        end)

      json(conn, %{object: "list", data: models})
    else
      {:error, reason} -> send_error(conn, 401, reason)
    end
  end

  # --- /v1/chat/completions ---

  def chat_completions(conn, params) do
    with :ok <- check_api_key(conn),
         model = Map.get(params, "model", "unknown"),
         {:ok, {provider, model_cfg}} <- resolve_provider(model) do
      params = maybe_fix_kimi_temperature(params, model)
      target_url = "#{provider.base_url}/chat/completions"
      headers = build_headers(provider, model_cfg)
      request = Finch.build(:post, target_url, headers, Jason.encode!(params))
      start_ms = System.monotonic_time(:millisecond)

      if Map.get(params, "stream", false) do
        do_stream(conn, request, model, start_ms)
      else
        do_regular(conn, request, model, start_ms)
      end
    else
      {:error, reason} when is_binary(reason) -> send_error(conn, 404, reason)
      {:error, reason} -> send_error(conn, 400, inspect(reason))
    end
  end

  # --- private helpers ---

  defp do_regular(conn, request, model, start_ms) do
    case Finch.request(request, Babel.Finch) do
      {:ok, response} ->
        duration = System.monotonic_time(:millisecond) - start_ms
        Babel.Stats.record(%{model: model, status: response.status, duration_ms: duration, stream: false})

        conn
        |> put_status(response.status)
        |> put_resp_content_type(get_content_type(response))
        |> send_resp(response.status, response.body)

      {:error, exception} ->
        duration = System.monotonic_time(:millisecond) - start_ms
        Babel.Stats.record(%{model: model, status: 502, duration_ms: duration, stream: false})
        Logger.error("Provider error: #{Exception.message(exception)}")
        send_error(conn, 502, "Provider error: #{Exception.message(exception)}")
    end
  end

  defp do_stream(conn, request, model, start_ms) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    try do
      Finch.stream(request, Babel.Finch, nil, fn
        {:data, data}, _acc ->
          case Plug.Conn.chunk(conn, data) do
            {:ok, _conn} -> nil
            {:error, _} -> throw(:client_disconnected)
          end

        _part, acc ->
          acc
      end)
    catch
      :client_disconnected -> :ok
    end

    duration = System.monotonic_time(:millisecond) - start_ms
    Babel.Stats.record(%{model: model, status: 200, duration_ms: duration, stream: true})

    conn
  rescue
    exception ->
      Logger.error("Stream error: #{Exception.message(exception)}")
      conn
  end

  defp resolve_provider(model) do
    config = ConfigLoader.get()

    model_cfg =
      config.models[model] ||
        Enum.find_value(config.models, fn {name, cfg} ->
          if String.contains?(name, model) or String.contains?(model, name), do: cfg
        end)

    case model_cfg do
      nil ->
        available = Map.keys(config.models) |> Enum.join(", ")
        {:error, "Model '#{model}' not found. Available: #{available}"}

      %Model{provider: pname} = cfg ->
        case config.providers[pname] do
          nil -> {:error, "Provider '#{pname}' not configured"}
          provider -> {:ok, {provider, cfg}}
        end
    end
  end

  defp build_headers(%Provider{api_key: key, default_headers: dh}, %Model{extra_headers: eh}) do
    base = [{"content-type", "application/json"}, {"authorization", "Bearer #{key}"}]
    dh_list = Enum.map(dh, fn {k, v} -> {k, v} end)
    eh_list = Enum.map(eh, fn {k, v} -> {k, v} end)
    base ++ dh_list ++ eh_list
  end

  defp maybe_fix_kimi_temperature(params, model) do
    if (String.contains?(model, "kimi-k2.5") or String.contains?(model, "kimi-k2.6")) and
         has_image_content(Map.get(params, "messages", [])) do
      Map.put(params, "temperature", 1)
    else
      params
    end
  end

  defp has_image_content(messages) do
    Enum.any?(messages, fn msg ->
      case msg["content"] do
        content when is_list(content) ->
          Enum.any?(content, fn
            %{"type" => t} when t in ["image_url", "image"] -> true
            _ -> false
          end)

        _ ->
          false
      end
    end)
  end

  defp check_api_key(conn) do
    config = ConfigLoader.get()

    case config.api_key do
      nil ->
        :ok

      expected ->
        auth = get_req_header(conn, "authorization") |> List.first("")

        if auth == "Bearer #{expected}" do
          :ok
        else
          {:error, "Invalid or missing API key"}
        end
    end
  end

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{message: message, type: "error", code: status}})
  end

  defp get_content_type(response) do
    Enum.find_value(response.headers, "application/json", fn
      {"content-type", v} -> v
      _ -> nil
    end)
  end
end
