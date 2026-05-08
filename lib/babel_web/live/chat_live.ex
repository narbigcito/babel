defmodule BabelWeb.ChatLive do
  use BabelWeb, :live_view

  alias Babel.ConfigLoader
  require Logger

  @virtual_provider "personalizado"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Babel.PubSub, "babel:config")

    config = ConfigLoader.get()
    {provider, model} = default_selection(config)

    {:ok,
     socket
     |> assign(:page_title, "Chat")
     |> assign(:config, config)
     |> assign(:selected_provider, provider)
     |> assign(:selected_model, model)
     |> assign(:models_for_provider, models_for(config, provider))
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:streaming, false)
     |> assign(:stream_id, nil)
     |> assign(:error, nil)
     |> assign(:show_settings, false)
     |> assign(:system_prompt, "")
     |> assign(:temperature, "")
     |> assign(:max_tokens, "")
     |> assign(:thinking_enabled, false)
     |> assign(:thinking_budget, "10000")
     |> assign(:preset_name_input, "")
     |> assign(:virtual_provider, @virtual_provider)}
  end

  @impl true
  def handle_info({:config_updated, config}, socket) do
    provider = socket.assigns.selected_provider
    model = socket.assigns.selected_model

    {provider, model} =
      cond do
        provider == @virtual_provider and Map.has_key?(config.presets, model) ->
          {provider, model}

        provider != @virtual_provider and Map.has_key?(config.providers, provider) and
            Enum.any?(config.models, fn {_, m} -> m.provider == provider and m.name == model end) ->
          {provider, model}

        true ->
          default_selection(config)
      end

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:selected_provider, provider)
     |> assign(:selected_model, model)
     |> assign(:models_for_provider, models_for(config, provider))}
  end

  @impl true
  def handle_info({:chunk, sid, {:content, text}}, %{assigns: %{stream_id: sid}} = socket) do
    {:noreply, assign(socket, :messages, append_content(socket.assigns.messages, text))}
  end

  @impl true
  def handle_info({:chunk, sid, {:thinking, text}}, %{assigns: %{stream_id: sid}} = socket) do
    {:noreply, assign(socket, :messages, append_thinking(socket.assigns.messages, text))}
  end

  @impl true
  def handle_info({:stream_done, sid}, %{assigns: %{stream_id: sid}} = socket) do
    {:noreply,
     socket
     |> assign(:streaming, false)
     |> assign(:messages, mark_done(socket.assigns.messages))}
  end

  @impl true
  def handle_info({:stream_error, sid, reason}, %{assigns: %{stream_id: sid}} = socket) do
    {:noreply,
     socket
     |> assign(:streaming, false)
     |> assign(:messages, replace_last(socket.assigns.messages, "⚠ Error: #{reason}"))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_provider", %{"provider" => name}, socket) do
    models = models_for(socket.assigns.config, name)
    first = List.first(models)

    socket =
      socket
      |> assign(:selected_provider, name)
      |> assign(:selected_model, first)
      |> assign(:models_for_provider, models)

    socket = if name == @virtual_provider and first != nil,
      do: load_preset_settings(socket, socket.assigns.config.presets[first]),
      else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"model" => name}, socket) do
    socket = assign(socket, :selected_model, name)

    socket =
      if socket.assigns.selected_provider == @virtual_provider do
        load_preset_settings(socket, socket.assigns.config.presets[name])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_input", %{"input" => v}, socket) do
    {:noreply, assign(socket, :input, v)}
  end

  @impl true
  def handle_event("toggle_settings", _params, socket) do
    {:noreply, assign(socket, :show_settings, !socket.assigns.show_settings)}
  end

  @impl true
  def handle_event("update_settings", params, socket) do
    socket =
      socket
      |> assign(:system_prompt, Map.get(params, "system_prompt", socket.assigns.system_prompt))
      |> assign(:temperature, Map.get(params, "temperature", socket.assigns.temperature))
      |> assign(:max_tokens, Map.get(params, "max_tokens", socket.assigns.max_tokens))
      |> assign(:thinking_budget, Map.get(params, "thinking_budget", socket.assigns.thinking_budget))
      |> assign(:preset_name_input, Map.get(params, "preset_name", socket.assigns.preset_name_input))

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_temperature", _params, socket) do
    {:noreply, assign(socket, :temperature, "")}
  end

  @impl true
  def handle_event("toggle_thinking", _params, socket) do
    {:noreply, assign(socket, :thinking_enabled, !socket.assigns.thinking_enabled)}
  end

  @impl true
  def handle_event("save_preset", _params, socket) do
    name = String.trim(socket.assigns.preset_name_input)

    if name == "" do
      {:noreply, assign(socket, :error, "El nombre del preset no puede estar vacío.")}
    else
      {provider, model} = effective_provider_model(socket)

      attrs = %{
        "provider" => provider,
        "model" => model,
        "system_prompt" => socket.assigns.system_prompt,
        "temperature" => socket.assigns.temperature,
        "max_tokens" => socket.assigns.max_tokens,
        "thinking_enabled" => socket.assigns.thinking_enabled,
        "thinking_budget" => socket.assigns.thinking_budget
      }

      case ConfigLoader.upsert_preset(name, attrs) do
        :ok ->
          {:noreply,
           socket
           |> assign(:preset_name_input, "")
           |> assign(:error, nil)}

        {:error, reason} ->
          {:noreply, assign(socket, :error, "Error al guardar: #{reason}")}
      end
    end
  end

  @impl true
  def handle_event("delete_preset", %{"name" => name}, socket) do
    case ConfigLoader.delete_preset(name) do
      :ok ->
        socket =
          if socket.assigns.selected_provider == @virtual_provider and
               socket.assigns.selected_model == name do
            assign(socket, :selected_provider, nil) |> assign(:selected_model, nil)
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Error: #{reason}")}
    end
  end

  @impl true
  def handle_event("send_message", %{"input" => content}, socket) do
    content = String.trim(content)
    {_provider, api_model} = effective_provider_model(socket)

    cond do
      content == "" or socket.assigns.streaming ->
        {:noreply, socket}

      api_model == nil ->
        {:noreply, assign(socket, :error, "Selecciona un proveedor y modelo primero.")}

      true ->
        user_msg = %{id: new_id(), role: "user", content: content, thinking: "", streaming: false}
        asst_msg = %{id: new_id(), role: "assistant", content: "", thinking: "", streaming: true}
        messages = socket.assigns.messages ++ [user_msg, asst_msg]

        api_messages =
          Enum.map(socket.assigns.messages ++ [user_msg], fn m ->
            %{"role" => m.role, "content" => m.content}
          end)

        api_messages =
          case String.trim(socket.assigns.system_prompt) do
            "" -> api_messages
            sp -> [%{"role" => "system", "content" => sp} | api_messages]
          end

        sid = new_id()
        lv_pid = self()
        config = socket.assigns.config

        chat_opts = %{
          temperature: parse_float(socket.assigns.temperature),
          max_tokens: parse_int(socket.assigns.max_tokens),
          thinking_enabled: socket.assigns.thinking_enabled,
          thinking_budget: parse_int(socket.assigns.thinking_budget) || 10000
        }

        Task.start(fn -> stream_chat(lv_pid, sid, api_model, api_messages, config, chat_opts) end)

        {:noreply,
         socket
         |> assign(:messages, messages)
         |> assign(:input, "")
         |> assign(:streaming, true)
         |> assign(:stream_id, sid)
         |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("clear", _p, socket) do
    {:noreply,
     socket |> assign(:messages, []) |> assign(:streaming, false) |> assign(:error, nil)}
  end

  @impl true
  def handle_event("dismiss_error", _p, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  # --- streaming worker ---

  defp stream_chat(pid, sid, model, messages, config, opts) do
    case resolve_provider(config, model) do
      {:ok, {provider, model_cfg}} ->
        url = "#{provider.base_url}/chat/completions"

        headers =
          [{"content-type", "application/json"}, {"authorization", "Bearer #{provider.api_key}"}] ++
            Enum.map(provider.default_headers, &{elem(&1, 0), elem(&1, 1)}) ++
            Enum.map(model_cfg.extra_headers, &{elem(&1, 0), elem(&1, 1)})

        body_map =
          %{model: model, messages: messages, stream: true}
          |> maybe_put(:temperature, opts.temperature)
          |> maybe_put(:max_tokens, opts.max_tokens)
          |> then(fn m ->
            if opts.thinking_enabled do
              Map.put(m, :thinking, %{type: "enabled", budget_tokens: opts.thinking_budget})
            else
              m
            end
          end)

        body = Jason.encode!(body_map)

        Logger.info("Chat stream → #{url} model=#{model}")

        try do
          result =
            Finch.stream(
              Finch.build(:post, url, headers, body),
              Babel.Finch,
              %{buf: "", status: nil},
              fn
                {:status, status}, acc -> %{acc | status: status}
                {:data, raw}, acc ->
                  buf = acc.buf <> raw
                  {chunks, buf} = parse_sse(buf)
                  Enum.each(chunks, fn
                    :done -> :ok
                    chunk -> send(pid, {:chunk, sid, chunk})
                  end)
                  %{acc | buf: buf}
                _, acc -> acc
              end
            )

          case result do
            {:ok, %{status: s, buf: body_buf}} when s != 200 ->
              reason = extract_api_error(body_buf, s)
              Logger.error("Chat stream HTTP #{s}: #{reason}")
              send(pid, {:stream_error, sid, reason})

            _ ->
              send(pid, {:stream_done, sid})
          end
        rescue
          e ->
            Logger.error("Chat stream error: #{Exception.message(e)}")
            send(pid, {:stream_error, sid, Exception.message(e)})
        end

      {:error, reason} ->
        Logger.error("Chat resolve error: #{reason}")
        send(pid, {:stream_error, sid, reason})
    end
  end

  defp parse_sse(buffer) do
    {lines, tail} =
      if String.ends_with?(buffer, "\n"),
        do: {String.split(buffer, "\n"), ""},
        else:
          (parts = String.split(buffer, "\n")
           {Enum.drop(parts, -1), List.last(parts)})

    chunks =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.flat_map(fn line ->
        json = binary_part(line, 6, byte_size(line) - 6)

        case json do
          "[DONE]" ->
            [:done]

          _ ->
            case Jason.decode(json) do
              {:ok, %{"choices" => [%{"delta" => delta} | _]}} ->
                [
                  {delta["content"], :content},
                  {delta["reasoning_content"], :thinking}
                ]
                |> Enum.flat_map(fn
                  {text, type} when is_binary(text) and text != "" -> [{type, text}]
                  _ -> []
                end)

              _ ->
                []
            end
        end
      end)

    {chunks, tail}
  end

  defp resolve_provider(config, model) do
    cfg =
      config.models[model] ||
        Enum.find_value(config.models, fn {n, c} ->
          if String.contains?(n, model) or String.contains?(model, n), do: c
        end)

    case cfg do
      nil -> {:error, "Modelo '#{model}' no encontrado en la configuración"}
      c ->
        case config.providers[c.provider] do
          nil -> {:error, "Proveedor '#{c.provider}' no configurado"}
          p -> {:ok, {p, c}}
        end
    end
  end

  defp effective_provider_model(socket) do
    if socket.assigns.selected_provider == @virtual_provider do
      preset = socket.assigns.config.presets[socket.assigns.selected_model]
      if preset, do: {preset.provider, preset.model}, else: {nil, nil}
    else
      {socket.assigns.selected_provider, socket.assigns.selected_model}
    end
  end

  defp load_preset_settings(socket, nil), do: socket

  defp load_preset_settings(socket, preset) do
    socket
    |> assign(:system_prompt, preset.system_prompt || "")
    |> assign(:temperature, if(preset.temperature != nil, do: to_string(preset.temperature), else: ""))
    |> assign(:max_tokens, if(preset.max_tokens != nil, do: to_string(preset.max_tokens), else: ""))
    |> assign(:thinking_enabled, preset.thinking_enabled)
    |> assign(:thinking_budget, to_string(preset.thinking_budget))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_api_error(body, status) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      {:ok, %{"message" => msg}} -> msg
      {:ok, %{"error" => msg}} when is_binary(msg) -> msg
      _ -> "HTTP #{status}"
    end
  end

  defp parse_float(""), do: nil
  defp parse_float(nil), do: nil

  defp parse_float(str) do
    case Float.parse(to_string(str)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(""), do: nil
  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(to_string(str)) do
      {i, _} when i > 0 -> i
      _ -> nil
    end
  end

  defp default_selection(%{providers: p}) when map_size(p) == 0, do: {nil, nil}

  defp default_selection(config) do
    {name, _} = Enum.min_by(config.providers, fn {n, _} -> n end)
    {name, models_for(config, name) |> List.first()}
  end

  defp models_for(_config, nil), do: []
  defp models_for(_config, ""), do: []

  defp models_for(config, @virtual_provider) do
    config.presets |> Map.keys() |> Enum.sort()
  end

  defp models_for(config, provider) do
    config.models
    |> Enum.filter(fn {_, m} -> m.provider == provider end)
    |> Enum.map(fn {n, _} -> n end)
    |> Enum.sort()
  end

  defp append_content(msgs, text),
    do: List.update_at(msgs, -1, &%{&1 | content: &1.content <> text})

  defp append_thinking(msgs, text),
    do: List.update_at(msgs, -1, &%{&1 | thinking: &1.thinking <> text})

  defp mark_done(msgs),
    do: List.update_at(msgs, -1, &%{&1 | streaming: false})

  defp replace_last(msgs, content),
    do: List.update_at(msgs, -1, &%{&1 | content: content, streaming: false})

  defp new_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col bg-zinc-950 text-zinc-100" style="height: calc(100vh - 49px)">

      <%!-- Toolbar --%>
      <div class="flex items-center gap-2 px-4 py-2.5 bg-zinc-900 border-b border-zinc-800 flex-shrink-0">
        <label class="text-xs text-zinc-500 whitespace-nowrap">Proveedor</label>
        <select
          phx-change="select_provider" name="provider" disabled={@streaming}
          class="bg-zinc-800 border border-zinc-700 rounded-lg px-2.5 py-1.5 text-sm text-zinc-200
                 focus:outline-none focus:ring-1 focus:ring-indigo-500 disabled:opacity-50 cursor-pointer"
        >
          <%= if @selected_provider == nil do %>
            <option value="">— sin proveedores —</option>
          <% else %>
            <%= for {name, _} <- Enum.sort(@config.providers) do %>
              <option value={name} selected={name == @selected_provider}><%= name %></option>
            <% end %>
            <%= if map_size(@config.presets) > 0 do %>
              <option value={@virtual_provider} selected={@selected_provider == @virtual_provider}>
                ★ Personalizado
              </option>
            <% end %>
          <% end %>
        </select>

        <label class="text-xs text-zinc-500 whitespace-nowrap ml-2">Modelo</label>
        <select
          phx-change="select_model" name="model"
          disabled={@streaming or @models_for_provider == []}
          class="bg-zinc-800 border border-zinc-700 rounded-lg px-2.5 py-1.5 text-sm text-zinc-200
                 focus:outline-none focus:ring-1 focus:ring-indigo-500 disabled:opacity-50 cursor-pointer"
        >
          <%= if @models_for_provider == [] do %>
            <option value="">— sin modelos —</option>
          <% else %>
            <%= for name <- @models_for_provider do %>
              <option value={name} selected={name == @selected_model}><%= name %></option>
            <% end %>
          <% end %>
        </select>

        <div class="flex-1" />

        <%= if @messages != [] do %>
          <button
            phx-click="clear" disabled={@streaming}
            class="text-xs text-zinc-600 hover:text-zinc-400 transition-colors disabled:opacity-40 px-2 py-1.5"
          >
            Limpiar
          </button>
        <% end %>

        <button
          phx-click="toggle_settings"
          title="Configuración"
          class={[
            "flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs transition-colors",
            if(@show_settings,
              do: "bg-indigo-600/20 text-indigo-400 border border-indigo-500/40",
              else: "text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800")
          ]}
        >
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
              d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0
                 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0
                 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0
                 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0
                 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0
                 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0
                 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0
                 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
              d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
          </svg>
          Config
        </button>
      </div>

      <%!-- Settings panel --%>
      <%= if @show_settings do %>
        <div class="bg-zinc-900/80 border-b border-zinc-800 px-4 py-4 flex-shrink-0">
          <form phx-change="update_settings" class="space-y-4">

            <%!-- System prompt --%>
            <div>
              <label class="block text-xs text-zinc-500 mb-1 font-medium">System Prompt</label>
              <textarea
                name="system_prompt"
                rows="2"
                placeholder="Ej: Eres un asistente útil y conciso."
                class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm
                       text-zinc-100 placeholder-zinc-600 focus:outline-none focus:ring-1
                       focus:ring-indigo-500 resize-none leading-relaxed"
              ><%= @system_prompt %></textarea>
            </div>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">

              <%!-- Temperature --%>
              <div>
                <label class="block text-xs text-zinc-500 mb-1 font-medium">
                  Temperature
                  <span class="text-zinc-400 ml-1 font-mono">
                    <%= if @temperature == "", do: "auto", else: @temperature %>
                  </span>
                  <%= if @temperature != "" do %>
                    <button type="button" phx-click="reset_temperature"
                      class="ml-1 text-zinc-600 hover:text-zinc-400 text-xs">✕</button>
                  <% end %>
                </label>
                <input
                  type="range" name="temperature"
                  min="0" max="1" step="0.05"
                  value={if @temperature == "", do: "0.6", else: @temperature}
                  class="w-full accent-indigo-500 cursor-pointer"
                />
                <div class="flex justify-between text-xs text-zinc-700 mt-0.5">
                  <span>0 preciso</span>
                  <span>1 creativo</span>
                </div>
              </div>

              <%!-- Max tokens --%>
              <div>
                <label class="block text-xs text-zinc-500 mb-1 font-medium">Max Tokens</label>
                <input
                  type="number" name="max_tokens"
                  min="1" max="131072" step="256"
                  value={@max_tokens}
                  placeholder="Sin límite"
                  class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm
                         text-zinc-100 placeholder-zinc-600 focus:outline-none focus:ring-1
                         focus:ring-indigo-500"
                />
              </div>

              <%!-- Thinking --%>
              <div>
                <label class="block text-xs text-zinc-500 mb-1 font-medium">Thinking</label>
                <p class="text-xs text-zinc-700 mb-2">Solo kimi-k2.5 / kimi-k2.6</p>
                <div class="flex items-center gap-3">
                  <button
                    type="button"
                    phx-click="toggle_thinking"
                    class={[
                      "relative inline-flex h-5 w-9 flex-shrink-0 cursor-pointer rounded-full border-2",
                      "border-transparent transition-colors duration-200 focus:outline-none",
                      if(@thinking_enabled, do: "bg-indigo-600", else: "bg-zinc-700")
                    ]}
                  >
                    <span class={[
                      "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow",
                      "transform transition duration-200",
                      if(@thinking_enabled, do: "translate-x-4", else: "translate-x-0")
                    ]}/>
                  </button>
                  <span class="text-xs text-zinc-400">
                    <%= if @thinking_enabled, do: "Activado", else: "Desactivado" %>
                  </span>
                </div>
                <%= if @thinking_enabled do %>
                  <div class="mt-2">
                    <label class="block text-xs text-zinc-600 mb-1">Budget tokens</label>
                    <input
                      type="number" name="thinking_budget"
                      min="1024" max="131072" step="1024"
                      value={@thinking_budget}
                      class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-1.5 text-sm
                             text-zinc-100 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                    />
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Save as preset --%>
            <div class="pt-3 border-t border-zinc-800">
              <label class="block text-xs text-zinc-500 mb-2 font-medium">Guardar como preset</label>
              <div class="flex gap-2">
                <input
                  type="text"
                  name="preset_name"
                  value={@preset_name_input}
                  placeholder="Nombre del preset..."
                  class="flex-1 bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-1.5 text-sm
                         text-zinc-100 placeholder-zinc-600 focus:outline-none focus:ring-1
                         focus:ring-indigo-500"
                />
                <button
                  type="button"
                  phx-click="save_preset"
                  class="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-xs
                         font-medium transition-colors whitespace-nowrap"
                >
                  Guardar
                </button>
              </div>
            </div>

            <%!-- List of saved presets --%>
            <%= if map_size(@config.presets) > 0 do %>
              <div class="pt-2">
                <label class="block text-xs text-zinc-600 mb-2">Presets guardados</label>
                <div class="flex flex-wrap gap-2">
                  <%= for {name, _preset} <- Enum.sort(@config.presets) do %>
                    <div class="flex items-center gap-1 bg-zinc-800 border border-zinc-700 rounded-lg px-2 py-1">
                      <span class="text-xs text-zinc-300"><%= name %></span>
                      <button
                        type="button"
                        phx-click="delete_preset"
                        phx-value-name={name}
                        class="text-zinc-600 hover:text-red-400 text-xs ml-1 transition-colors"
                        title="Eliminar preset"
                      >✕</button>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

          </form>
        </div>
      <% end %>

      <%!-- Error --%>
      <%= if @error do %>
        <div class="flex items-center gap-2 px-4 py-2.5 bg-red-950/60 border-b border-red-900 text-red-400 text-sm">
          <%= @error %>
          <button phx-click="dismiss_error" class="ml-auto text-red-600 hover:text-red-400">✕</button>
        </div>
      <% end %>

      <%!-- Messages --%>
      <div id="messages" phx-hook="ScrollBottom"
           class="flex-1 overflow-y-auto px-4 py-6 space-y-6">

        <%= if @messages == [] do %>
          <div class="flex flex-col items-center justify-center h-full gap-3 text-center select-none">
            <div class="w-12 h-12 rounded-2xl bg-indigo-600/20 border border-indigo-500/30
                        flex items-center justify-center text-indigo-400 text-xl">
              ✦
            </div>
            <%= if @selected_model do %>
              <p class="text-zinc-400 text-sm">
                <%= if @selected_provider == @virtual_provider do %>
                  Preset <span class="text-white font-medium"><%= @selected_model %></span>
                <% else %>
                  Chateando con <span class="text-white font-medium"><%= @selected_model %></span>
                <% end %>
              </p>
              <p class="text-zinc-600 text-xs">Escribe un mensaje para empezar</p>
            <% else %>
              <p class="text-zinc-500 text-sm">Selecciona un proveedor y modelo para empezar</p>
            <% end %>
          </div>
        <% else %>
          <%= for msg <- @messages do %>
            <%= if msg.role == "user" do %>
              <div class="flex justify-end">
                <div class="max-w-[75%] bg-indigo-600 text-white rounded-2xl rounded-tr-md
                            px-4 py-3 text-sm leading-relaxed shadow-lg">
                  <%= msg.content %>
                </div>
              </div>
            <% else %>
              <div class="flex items-start gap-3 max-w-[85%]">
                <div class="flex-shrink-0 w-8 h-8 rounded-xl bg-zinc-800 border border-zinc-700
                            flex items-center justify-center text-xs font-bold text-indigo-400 mt-0.5">
                  AI
                </div>
                <div class="flex-1">
                  <div class="text-xs text-zinc-600 mb-1.5 font-medium">
                    <%= @selected_model %>
                  </div>
                  <%= if msg.thinking != "" do %>
                    <details class="mb-2 group">
                      <summary class="text-xs text-zinc-600 hover:text-zinc-400 cursor-pointer select-none
                                      flex items-center gap-1 list-none">
                        <span class="group-open:rotate-90 transition-transform inline-block">▶</span>
                        <span class="italic">
                          Pensando<%= if msg.streaming and msg.content == "", do: "...", else: "" %>
                        </span>
                      </summary>
                      <div class="mt-2 pl-3 border-l border-zinc-700 text-xs text-zinc-500
                                  leading-relaxed whitespace-pre-wrap max-h-48 overflow-y-auto">
                        <%= msg.thinking %>
                        <%= if msg.streaming and msg.content == "" do %>
                          <span class="inline-block w-0.5 h-[1em] bg-zinc-600 animate-pulse ml-px align-text-bottom"></span>
                        <% end %>
                      </div>
                    </details>
                  <% end %>

                  <div class="bg-zinc-900 border border-zinc-800 rounded-2xl rounded-tl-md
                              px-4 py-3 text-sm leading-relaxed text-zinc-100 shadow-sm">
                    <%= if msg.content == "" and msg.streaming do %>
                      <span class="flex gap-1 items-center h-5">
                        <span class="w-1.5 h-1.5 bg-zinc-500 rounded-full animate-bounce [animation-delay:0ms]"></span>
                        <span class="w-1.5 h-1.5 bg-zinc-500 rounded-full animate-bounce [animation-delay:150ms]"></span>
                        <span class="w-1.5 h-1.5 bg-zinc-500 rounded-full animate-bounce [animation-delay:300ms]"></span>
                      </span>
                    <% else %>
                      <span class="whitespace-pre-wrap"><%= msg.content %></span>
                      <%= if msg.streaming do %>
                        <span class="inline-block w-0.5 h-[1.1em] bg-indigo-400 animate-pulse ml-px align-text-bottom"></span>
                      <% end %>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>

      <%!-- Input --%>
      <div class="px-4 py-4 bg-zinc-900/50 border-t border-zinc-800 flex-shrink-0">
        <form phx-submit="send_message" class="flex items-end gap-3">
          <textarea
            id="chat-input"
            name="input"
            rows="1"
            phx-change="update_input"
            phx-hook="ChatInput"
            value={@input}
            placeholder={if @streaming, do: "Esperando respuesta...", else: "Escribe un mensaje... (Enter para enviar)"}
            disabled={@streaming or @selected_model == nil}
            autocomplete="off"
            class="flex-1 resize-none bg-zinc-800 border border-zinc-700 rounded-2xl px-4 py-3 text-sm
                   text-zinc-100 placeholder-zinc-600 focus:outline-none focus:ring-2 focus:ring-indigo-500/60
                   focus:border-indigo-500/60 disabled:opacity-50 transition-colors leading-relaxed"
          ></textarea>
          <button
            type="submit"
            disabled={@streaming or String.trim(@input) == "" or @selected_model == nil}
            class="flex-shrink-0 w-11 h-11 rounded-2xl bg-indigo-600 hover:bg-indigo-500 active:bg-indigo-700
                   flex items-center justify-center text-white transition-colors
                   disabled:opacity-40 disabled:cursor-not-allowed shadow-lg"
          >
            <%= if @streaming do %>
              <svg class="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
              </svg>
            <% else %>
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"/>
              </svg>
            <% end %>
          </button>
        </form>
      </div>

    </div>
    """
  end
end
