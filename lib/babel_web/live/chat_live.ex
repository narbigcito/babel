defmodule BabelWeb.ChatLive do
  use BabelWeb, :live_view

  alias Babel.ConfigLoader
  require Logger

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

  @impl true
  def handle_info({:config_updated, config}, socket) do
    provider = socket.assigns.selected_provider
    model = socket.assigns.selected_model

    {provider, model} =
      if Map.has_key?(config.providers, provider) and
           Enum.any?(config.models, fn {_, m} -> m.provider == provider and m.name == model end),
         do: {provider, model},
         else: default_selection(config)

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

    {:noreply,
     socket
     |> assign(:selected_provider, name)
     |> assign(:selected_model, List.first(models))
     |> assign(:models_for_provider, models)}
  end

  @impl true
  def handle_event("select_model", %{"model" => name}, socket) do
    {:noreply, assign(socket, :selected_model, name)}
  end

  @impl true
  def handle_event("update_input", %{"input" => v}, socket) do
    {:noreply, assign(socket, :input, v)}
  end

  @impl true
  def handle_event("send_message", %{"input" => content}, socket) do
    content = String.trim(content)

    cond do
      content == "" or socket.assigns.streaming ->
        {:noreply, socket}

      socket.assigns.selected_model == nil ->
        {:noreply, assign(socket, :error, "Selecciona un proveedor y modelo primero.")}

      true ->
        user_msg = %{id: new_id(), role: "user", content: content, thinking: "", streaming: false}
        asst_msg = %{id: new_id(), role: "assistant", content: "", thinking: "", streaming: true}
        messages = socket.assigns.messages ++ [user_msg, asst_msg]

        api_messages =
          Enum.map(socket.assigns.messages ++ [user_msg], fn m ->
            %{"role" => m.role, "content" => m.content}
          end)

        sid = new_id()
        lv_pid = self()
        model = socket.assigns.selected_model
        config = socket.assigns.config

        Task.start(fn -> stream_chat(lv_pid, sid, model, api_messages, config) end)

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

  defp stream_chat(pid, sid, model, messages, config) do
    case resolve_provider(config, model) do
      {:ok, {provider, model_cfg}} ->
        url = "#{provider.base_url}/chat/completions"

        headers =
          [{"content-type", "application/json"}, {"authorization", "Bearer #{provider.api_key}"}] ++
            Enum.map(provider.default_headers, &{elem(&1, 0), elem(&1, 1)}) ++
            Enum.map(model_cfg.extra_headers, &{elem(&1, 0), elem(&1, 1)})

        body = Jason.encode!(%{model: model, messages: messages, stream: true})

        Logger.info("Chat stream → #{url} model=#{model}")

        try do
          Finch.stream(Finch.build(:post, url, headers, body), Babel.Finch, "", fn
            {:data, raw}, buf ->
              buf = buf <> raw
              {chunks, buf} = parse_sse(buf)
              Enum.each(chunks, fn
                :done -> :ok
                chunk -> send(pid, {:chunk, sid, chunk})
              end)
              buf
            _, buf -> buf
          end)

          send(pid, {:stream_done, sid})
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
      nil -> {:error, "Modelo '#{model}' no encontrado"}
      c ->
        case config.providers[c.provider] do
          nil -> {:error, "Proveedor '#{c.provider}' no configurado"}
          p -> {:ok, {p, c}}
        end
    end
  end

  defp default_selection(%{providers: p}) when map_size(p) == 0, do: {nil, nil}

  defp default_selection(config) do
    {name, _} = Enum.min_by(config.providers, fn {n, _} -> n end)
    {name, models_for(config, name) |> List.first()}
  end

  defp models_for(_config, nil), do: []

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
      </div>

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
                Chateando con <span class="text-white font-medium"><%= @selected_model %></span>
              </p>
              <p class="text-zinc-600 text-xs">Escribe un mensaje para empezar</p>
            <% else %>
              <p class="text-zinc-500 text-sm">Selecciona un proveedor y modelo para empezar</p>
            <% end %>
          </div>
        <% else %>
          <%= for msg <- @messages do %>
            <%= if msg.role == "user" do %>
              <%!-- User message --%>
              <div class="flex justify-end">
                <div class="max-w-[75%] bg-indigo-600 text-white rounded-2xl rounded-tr-md
                            px-4 py-3 text-sm leading-relaxed shadow-lg">
                  <%= msg.content %>
                </div>
              </div>
            <% else %>
              <%!-- Assistant message --%>
              <div class="flex items-start gap-3 max-w-[85%]">
                <div class="flex-shrink-0 w-8 h-8 rounded-xl bg-zinc-800 border border-zinc-700
                            flex items-center justify-center text-xs font-bold text-indigo-400 mt-0.5">
                  AI
                </div>
                <div class="flex-1">
                  <div class="text-xs text-zinc-600 mb-1.5 font-medium">
                    <%= @selected_model %>
                  </div>
                  <%!-- Thinking block (colapsable) --%>
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
