defmodule BabelWeb.ProvidersLive do
  use BabelWeb, :live_view

  alias Babel.ConfigLoader

  @empty_form %{"name" => "", "base_url" => "", "api_key" => "", "default_headers" => ""}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Babel.PubSub, "babel:config")

    config = ConfigLoader.get()

    {:ok,
     socket
     |> assign(:page_title, "Providers")
     |> assign(:providers, config.providers)
     |> assign(:mode, :list)
     |> assign(:form_data, @empty_form)
     |> assign(:errors, %{})
     |> assign(:confirm_delete, nil)
     |> assign(:flash_msg, nil)}
  end

  @impl true
  def handle_info({:config_updated, config}, socket) do
    {:noreply, assign(socket, :providers, config.providers)}
  end

  # --- events ---

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(:mode, :new) |> assign(:form_data, @empty_form) |> assign(:errors, %{})}
  end

  @impl true
  def handle_event("edit", %{"name" => name}, socket) do
    provider = socket.assigns.providers[name]

    form_data = %{
      "name" => name,
      "base_url" => provider.base_url,
      "api_key" => provider.api_key,
      "default_headers" =>
        if(map_size(provider.default_headers) > 0,
          do: Jason.encode!(provider.default_headers, pretty: true),
          else: ""
        )
    }

    {:noreply, socket |> assign(:mode, {:edit, name}) |> assign(:form_data, form_data) |> assign(:errors, %{})}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:mode, :list) |> assign(:confirm_delete, nil)}
  end

  @impl true
  def handle_event("validate", %{"provider" => data}, socket) do
    {:noreply, socket |> assign(:form_data, data) |> assign(:errors, validate(data, socket.assigns.mode, socket.assigns.providers))}
  end

  @impl true
  def handle_event("save", %{"provider" => data}, socket) do
    errors = validate(data, socket.assigns.mode, socket.assigns.providers)

    if errors == %{} do
      name =
        case socket.assigns.mode do
          :new -> data["name"]
          {:edit, n} -> n
        end

      case ConfigLoader.upsert_provider(name, data) do
        :ok ->
          {:noreply,
           socket
           |> assign(:mode, :list)
           |> assign(:flash_msg, {:ok, "Proveedor '#{name}' guardado."})}

        {:error, reason} ->
          {:noreply, assign(socket, :flash_msg, {:error, "Error: #{reason}"})}
      end
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"name" => name}, socket) do
    {:noreply, assign(socket, :confirm_delete, name)}
  end

  @impl true
  def handle_event("delete", %{"name" => name}, socket) do
    case ConfigLoader.delete_provider(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> assign(:flash_msg, {:ok, "Proveedor '#{name}' eliminado."})}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, {:error, "Error: #{reason}"})}
    end
  end

  @impl true
  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  # --- validation ---

  defp validate(data, mode, providers) do
    errors = %{}

    errors =
      if mode == :new do
        name = String.trim(data["name"] || "")

        cond do
          name == "" -> Map.put(errors, :name, "Requerido")
          not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) -> Map.put(errors, :name, "Solo letras, números, _ y -")
          Map.has_key?(providers, name) -> Map.put(errors, :name, "Ya existe un proveedor con ese nombre")
          true -> errors
        end
      else
        errors
      end

    errors =
      if String.trim(data["base_url"] || "") == "" do
        Map.put(errors, :base_url, "Requerido")
      else
        errors
      end

    errors =
      if String.trim(data["api_key"] || "") == "" do
        Map.put(errors, :api_key, "Requerido")
      else
        errors
      end

    errors =
      case data["default_headers"] do
        "" -> errors
        nil -> errors
        str ->
          case Jason.decode(str) do
            {:ok, map} when is_map(map) -> errors
            _ -> Map.put(errors, :default_headers, "Debe ser JSON válido, ej: {\"X-Header\": \"valor\"}")
          end
      end

    errors
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-100 font-mono">

      <%!-- Flash --%>
      <%= if @flash_msg do %>
        <div class={[
          "fixed top-4 right-4 z-50 px-4 py-3 rounded-lg text-sm flex items-center gap-3 shadow-lg",
          if(elem(@flash_msg, 0) == :ok, do: "bg-emerald-900 text-emerald-300 border border-emerald-700",
             else: "bg-red-900 text-red-300 border border-red-700")
        ]}>
          <%= elem(@flash_msg, 1) %>
          <button phx-click="dismiss_flash" class="ml-2 opacity-70 hover:opacity-100">✕</button>
        </div>
      <% end %>

      <div class="max-w-3xl mx-auto p-6">

        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-xl font-bold">Providers</h1>
          <%= if @mode == :list do %>
            <button
              phx-click="new"
              class="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-500 rounded text-sm font-medium transition-colors"
            >
              + Agregar
            </button>
          <% end %>
        </div>

        <%!-- Add / Edit form --%>
        <%= if @mode != :list do %>
          <div class="bg-zinc-900 border border-zinc-700 rounded-lg p-5 mb-6">
            <h2 class="text-sm font-semibold text-zinc-400 mb-4">
              <%= if @mode == :new, do: "Nuevo proveedor", else: "Editar proveedor" %>
            </h2>

            <form phx-change="validate" phx-submit="save">
              <%= if @mode == :new do %>
                <.field label="Nombre" name="provider[name]" value={@form_data["name"]} error={@errors[:name]}
                  placeholder="ej: openai" />
              <% else %>
                <div class="mb-4">
                  <label class="block text-xs text-zinc-500 mb-1">Nombre</label>
                  <p class="text-zinc-300"><%= elem(@mode, 1) %></p>
                </div>
              <% end %>

              <.field label="Base URL" name="provider[base_url]" value={@form_data["base_url"]} error={@errors[:base_url]}
                placeholder="https://api.openai.com/v1" />

              <.field label="API Key" name="provider[api_key]" value={@form_data["api_key"]} error={@errors[:api_key]}
                placeholder="sk-..." type="password" />

              <.field label="Default Headers (JSON, opcional)" name="provider[default_headers]"
                value={@form_data["default_headers"]} error={@errors[:default_headers]}
                placeholder={"{\"X-Custom-Header\": \"valor\"}"} />

              <div class="flex gap-2 mt-5">
                <button type="submit"
                  class="px-4 py-2 bg-indigo-600 hover:bg-indigo-500 rounded text-sm font-medium transition-colors">
                  Guardar
                </button>
                <button type="button" phx-click="cancel"
                  class="px-4 py-2 bg-zinc-700 hover:bg-zinc-600 rounded text-sm font-medium transition-colors">
                  Cancelar
                </button>
              </div>
            </form>
          </div>
        <% end %>

        <%!-- Providers list --%>
        <div class="bg-zinc-900 border border-zinc-800 rounded-lg overflow-hidden">
          <%= if map_size(@providers) == 0 do %>
            <div class="p-8 text-center text-zinc-600 text-sm">
              No hay proveedores configurados.
            </div>
          <% else %>
            <table class="w-full text-sm">
              <thead>
                <tr class="text-xs text-zinc-500 uppercase tracking-wider border-b border-zinc-800">
                  <th class="text-left px-4 py-3">Nombre</th>
                  <th class="text-left px-4 py-3">Base URL</th>
                  <th class="text-left px-4 py-3">API Key</th>
                  <th class="px-4 py-3"></th>
                </tr>
              </thead>
              <tbody>
                <%= for {name, provider} <- Enum.sort_by(@providers, fn {n, _} -> n end) do %>
                  <tr class="border-t border-zinc-800 hover:bg-zinc-800/40">
                    <td class="px-4 py-3 font-semibold text-zinc-200"><%= name %></td>
                    <td class="px-4 py-3 text-zinc-400 text-xs"><%= provider.base_url %></td>
                    <td class="px-4 py-3 text-zinc-600 text-xs font-mono">
                      <%= mask_key(provider.api_key) %>
                    </td>
                    <td class="px-4 py-3 text-right">
                      <%= if @confirm_delete == name do %>
                        <span class="text-xs text-zinc-400 mr-2">¿Eliminar?</span>
                        <button phx-click="delete" phx-value-name={name}
                          class="text-xs text-red-400 hover:text-red-300 mr-2 font-medium">
                          Sí
                        </button>
                        <button phx-click="cancel"
                          class="text-xs text-zinc-500 hover:text-zinc-300">
                          No
                        </button>
                      <% else %>
                        <button phx-click="edit" phx-value-name={name}
                          class="text-xs text-zinc-400 hover:text-white mr-3 transition-colors">
                          Editar
                        </button>
                        <button phx-click="confirm_delete" phx-value-name={name}
                          class="text-xs text-zinc-600 hover:text-red-400 transition-colors">
                          Eliminar
                        </button>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>

      </div>
    </div>
    """
  end

  # --- private components ---

  defp field(assigns) do
    assigns = Map.put_new(assigns, :type, "text")

    ~H"""
    <div class="mb-4">
      <label class="block text-xs text-zinc-500 mb-1"><%= @label %></label>
      <input
        type={@type}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        phx-debounce="300"
        class={[
          "w-full bg-zinc-800 border rounded px-3 py-2 text-sm text-zinc-100 placeholder-zinc-600",
          "focus:outline-none focus:ring-1 focus:ring-indigo-500",
          if(@error, do: "border-red-600", else: "border-zinc-700")
        ]}
      />
      <%= if @error do %>
        <p class="text-xs text-red-400 mt-1"><%= @error %></p>
      <% end %>
    </div>
    """
  end

  defp mask_key(""), do: "—"
  defp mask_key(key) when byte_size(key) <= 8, do: String.duplicate("•", byte_size(key))

  defp mask_key(key) do
    prefix = String.slice(key, 0, 6)
    prefix <> "••••" <> String.slice(key, -4, 4)
  end
end
