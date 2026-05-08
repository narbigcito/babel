defmodule BabelWeb.ChatLive do
  use BabelWeb, :live_view

  alias Babel.ConfigLoader
  alias Babel.ConfigLoader.Provider

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
     |> assign(:error, nil)}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:config_updated, config}, socket) do
    provider = socket.assigns.selected_provider
    model = socket.assigns.selected_model

    # Keep selection if still valid, otherwise reset
    {provider, model} =
      if Map.has_key?(config.providers, provider) and
           Enum.any?(config.models, fn {_, m} -> m.provider == provider and m.name == model end) do
        {provider, model}
      else
        default_selection(config)
      end

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:selected_provider, provider)
     |> assign(:selected_model, model)
     |> assign(:models_for_provider, models_for(config, provider))}
  end

  # --- Stream callbacks from Task ---

  @impl true
  def handle_info({:chunk, stream_id, content}, socket) do
    if socket.assigns.stream_id == stream_id do
      messages = append_to_last(socket.assigns.messages, content)
      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:stream_done, stream_id}, socket) do
    if socket.assigns.stream_id == stream_id do
      messages = mark_done(socket.assigns.messages)
      {:noreply, socket |> assign(:streaming, false) |> assign(:messages, messages)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:stream_error, stream_id, reason}, socket) do
    if socket.assigns.stream_id == stream_id do
      messages = replace_last(socket.assigns.messages, "⚠ Error: #{reason}", false)
      {:noreply, socket |> assign(:streaming, false) |> assign(:messages, messages)}
    else
      {:noreply, socket}
    end
  end

  # --- Events ---

  @impl true
  def handle_event("select_provider", %{"provider" => name}, socket) do
    models = models_for(socket.assigns.config, name)
    model = List.first(models)

    {:noreply,
     socket
     |> assign(:selected_provider, name)
     |> assign(:selected_model, model)
     |> assign(:models_for_provider, models)}
  end

  @impl true
  def handle_event("select_model", %{"model" => name}, socket) do
    {:noreply, assign(socket, :selected_model, name)}
  end

  @impl true
  def handle_event("update_input", %{"input" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  @impl true
  def handle_event("send_message", %{"input" => content}, socket) do
    content = String.trim(content)

    cond do
      content == "" ->
        {:noreply, socket}

      socket.assigns.streaming ->
        {:noreply, socket}

      socket.assigns.selected_model == nil ->
        {:noreply, assign(socket, :error, "Selecciona un modelo primero.")}

      true ->
        user_msg = %{id: new_id(), role: "user", content: content, streaming: false}
        asst_msg = %{id: new_id(), role: "assistant", content: "", streaming: true}

        messages = socket.assigns.messages ++ [user_msg, asst_msg]
        stream_id = new_id()

        # API messages (exclude streaming state)
        api_messages = Enum.map(socket.assigns.messages ++ [user_msg], fn m ->
          %{"role" => m.role, "content" => m.content}
        end)

        liveview_pid = self()
        model = socket.assigns.selected_model
        config = socket.assigns.config

        Task.start(fn ->
          stream_chat(liveview_pid, stream_id, model, api_messages, config)
        end)

        {:noreply,
         socket
         |> assign(:messages, messages)
         |> assign(:input, "")
         |> assign(:streaming, true)
         |> assign(:stream_id, stream_id)
         |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:streaming, false)
     |> assign(:stream_id, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  # --- Streaming worker ---

  defp stream_chat(pid, stream_id, model, messages, config) do
    case resolve_provider(config, model) do
      {:ok, {provider, model_cfg}} ->
        target_url = "#{provider.base_url}/chat/completions"

        headers = [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{provider.api_key}"}
        ] ++
          Enum.map(provider.default_headers, fn {k, v} -> {k, v} end) ++
          Enum.map(model_cfg.extra_headers, fn {k, v} -> {k, v} end)

        body = Jason.encode!(%{model: model, messages: messages, stream: true})
        request = Finch.build(:post, target_url, headers, body)

        try do
          Finch.stream(request, Babel.Finch, "", fn
            {:data, raw}, buffer ->
              buffer = buffer <> raw
              {chunks, buffer} = parse_sse(buffer)

              Enum.each(chunks, fn
                :done -> :ok
                text -> send(pid, {:chunk, stream_id, text})
              end)

              buffer

            _, buffer ->
              buffer
          end)

          send(pid, {:stream_done, stream_id})
        rescue
          e -> send(pid, {:stream_error, stream_id, Exception.message(e)})
        end

      {:error, reason} ->
        send(pid, {:stream_error, stream_id, reason})
    end
  end

  defp parse_sse(buffer) do
    # Split into lines, process complete ones, keep incomplete tail
    lines = String.split(buffer, "\n")

    {complete_lines, tail} =
      if String.ends_with?(buffer, "\n") do
        {lines, ""}
      else
        {Enum.drop(lines, -1), List.last(lines)}
      end

    chunks =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.flat_map(fn line ->
        json = binary_part(line, 6, byte_size(line) - 6)

        case json do
          "[DONE]" ->
            [:done]

          _ ->
            case Jason.decode(json) do
              {:ok, %{"choices" => [%{"delta" => %{"content" => c}} | _]}} when is_binary(c) ->
                [c]
              _ ->
                []
            end
        end
      end)

    {chunks, tail}
  end

  defp resolve_provider(config, model) do
    model_cfg =
      config.models[model] ||
        Enum.find_value(config.models, fn {name, cfg} ->
          if String.contains?(name, model) or String.contains?(model, name), do: cfg
        end)

    case model_cfg do
      nil -> {:error, "Modelo '#{model}' no encontrado"}
      cfg ->
        case config.providers[cfg.provider] do
          nil -> {:error, "Proveedor '#{cfg.provider}' no configurado"}
          provider -> {:ok, {provider, cfg}}
        end
    end
  end

  # --- Helpers ---

  defp default_selection(%{providers: providers, models: models})
       when map_size(providers) == 0 or map_size(models) == 0,
       do: {nil, nil}

  defp default_selection(config) do
    {provider_name, _} = Enum.min_by(config.providers, fn {name, _} -> name end)
    model = models_for(config, provider_name) |> List.first()
    {provider_name, model}
  end

  defp models_for(config, nil), do: []

  defp models_for(config, provider_name) do
    config.models
    |> Enum.filter(fn {_, m} -> m.provider == provider_name end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  defp append_to_last(messages, content) do
    List.update_at(messages, -1, fn m -> %{m | content: m.content <> content} end)
  end

  defp mark_done(messages) do
    List.update_at(messages, -1, fn m -> %{m | streaming: false} end)
  end

  defp replace_last(messages, content, streaming) do
    List.update_at(messages, -1, fn m -> %{m | content: content, streaming: streaming} end)
  end

  defp new_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-[calc(100vh-49px)] bg-zinc-950 text-zinc-100 font-mono">

      <%!-- Toolbar --%>
      <div class="flex items-center gap-3 px-4 py-3 border-b border-zinc-800 bg-zinc-900 flex-shrink-0">
        <%!-- Provider selector --%>
        <div class="flex items-center gap-2">
          <span class="text-xs text-zinc-500">Proveedor</span>
          <select
            phx-change="select_provider"
            name="provider"
            disabled={@streaming}
            class="bg-zinc-800 border border-zinc-700 rounded px-2 py-1 text-sm text-zinc-200
                   focus:outline-none focus:ring-1 focus:ring-indigo-500 disabled:opacity-50"
          >
            <%= if @selected_provider == nil do %>
              <option value="">Sin proveedores</option>
            <% else %>
              <%= for {name, _} <- Enum.sort(@config.providers) do %>
                <option value={name} selected={name == @selected_provider}><%= name %></option>
              <% end %>
            <% end %>
          </select>
        </div>

        <span class="text-zinc-700">·</span>

        <%!-- Model selector --%>
        <div class="flex items-center gap-2">
          <span class="text-xs text-zinc-500">Modelo</span>
          <select
            phx-change="select_model"
            name="model"
            disabled={@streaming or @models_for_provider == []}
            class="bg-zinc-800 border border-zinc-700 rounded px-2 py-1 text-sm text-zinc-200
                   focus:outline-none focus:ring-1 focus:ring-indigo-500 disabled:opacity-50"
          >
            <%= if @models_for_provider == [] do %>
              <option value="">Sin modelos</option>
            <% else %>
              <%= for name <- @models_for_provider do %>
                <option value={name} selected={name == @selected_model}><%= name %></option>
              <% end %>
            <% end %>
          </select>
        </div>

        <div class="flex-1"></div>

        <%= if @messages != [] do %>
          <button
            phx-click="clear"
            disabled={@streaming}
            class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors disabled:opacity-50"
          >
            Limpiar chat
          </button>
        <% end %>
      </div>

      <%!-- Error banner --%>
      <%= if @error do %>
        <div class="flex items-center gap-2 px-4 py-2 bg-red-950 border-b border-red-800 text-red-300 text-xs">
          <span><%= @error %></span>
          <button phx-click="dismiss_error" class="ml-auto opacity-70 hover:opacity-100">✕</button>
        </div>
      <% end %>

      <%!-- Messages --%>
      <div
        id="messages"
        phx-hook="ScrollBottom"
        class="flex-1 overflow-y-auto px-4 py-4 space-y-4"
      >
        <%= if @messages == [] do %>
          <div class="flex items-center justify-center h-full text-zinc-600 text-sm">
            <%= if @selected_model do %>
              Escribe un mensaje para empezar a chatear con <span class="text-zinc-400 ml-1"><%= @selected_model %></span>
            <% else %>
              Configura un proveedor y modelo para empezar.
            <% end %>
          </div>
        <% else %>
          <%= for msg <- @messages do %>
            <div class={[
              "flex",
              if(msg.role == "user", do: "justify-end", else: "justify-start")
            ]}>
              <div class={[
                "max-w-[80%] rounded-lg px-4 py-2.5 text-sm leading-relaxed",
                if(msg.role == "user",
                  do: "bg-indigo-700 text-white",
                  else: "bg-zinc-800 text-zinc-100 border border-zinc-700")
              ]}>
                <%= if msg.role == "assistant" and msg.content == "" and msg.streaming do %>
                  <span class="inline-flex gap-1 items-center text-zinc-500">
                    <span class="w-1.5 h-1.5 bg-zinc-500 rounded-full animate-bounce" style="animation-delay:0ms"></span>
                    <span class="w-1.5 h-1.5 bg-zinc-500 rounded-full animate-bounce" style="animation-delay:150ms"></span>
                    <span class="w-1.5 h-1.5 bg-zinc-500 rounded-full animate-bounce" style="animation-delay:300ms"></span>
                  </span>
                <% else %>
                  <span class="whitespace-pre-wrap"><%= msg.content %></span>
                  <%= if msg.streaming do %>
                    <span class="inline-block w-0.5 h-4 bg-zinc-400 animate-pulse ml-0.5 align-middle"></span>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>

      <%!-- Input --%>
      <div class="px-4 py-3 border-t border-zinc-800 bg-zinc-900 flex-shrink-0">
        <form phx-submit="send_message" class="flex gap-2">
          <input
            id="chat-input"
            type="text"
            name="input"
            value={@input}
            phx-change="update_input"
            phx-hook="ChatInput"
            placeholder={if @streaming, do: "Esperando respuesta...", else: "Escribe un mensaje..."}
            disabled={@streaming or @selected_model == nil}
            autocomplete="off"
            class="flex-1 bg-zinc-800 border border-zinc-700 rounded-lg px-4 py-2.5 text-sm
                   text-zinc-100 placeholder-zinc-600 focus:outline-none focus:ring-1
                   focus:ring-indigo-500 disabled:opacity-50"
          />
          <button
            type="submit"
            disabled={@streaming or @input == "" or @selected_model == nil}
            class="px-4 py-2.5 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-sm font-medium
                   transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            <%= if @streaming do %>
              <span class="inline-block w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin"></span>
            <% else %>
              Enviar
            <% end %>
          </button>
        </form>
      </div>

    </div>
    """
  end
end
