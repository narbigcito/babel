defmodule BabelWeb.UsersLive do
  use BabelWeb, :live_view

  alias Babel.ConfigLoader

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Babel.PubSub, "babel:config")

    config = ConfigLoader.get()

    {:ok,
     socket
     |> assign(:page_title, "Usuarios")
     |> assign(:users, config.users)
     |> assign(:mode, :list)
     |> assign(:form_username, "")
     |> assign(:form_password, "")
     |> assign(:form_password2, "")
     |> assign(:editing, nil)
     |> assign(:confirm_delete, nil)
     |> assign(:errors, %{})
     |> assign(:flash_msg, nil)}
  end

  @impl true
  def handle_info({:config_updated, config}, socket) do
    {:noreply, assign(socket, :users, config.users)}
  end

  # --- events ---

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:mode, :new)
     |> assign(:form_username, "")
     |> assign(:form_password, "")
     |> assign(:form_password2, "")
     |> assign(:errors, %{})}
  end

  @impl true
  def handle_event("edit", %{"username" => username}, socket) do
    {:noreply,
     socket
     |> assign(:mode, :edit)
     |> assign(:editing, username)
     |> assign(:form_password, "")
     |> assign(:form_password2, "")
     |> assign(:errors, %{})}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:mode, :list) |> assign(:confirm_delete, nil)}
  end

  @impl true
  def handle_event("validate", %{"user" => data}, socket) do
    {:noreply,
     socket
     |> assign(:form_username, Map.get(data, "username", socket.assigns.form_username))
     |> assign(:form_password, Map.get(data, "password", socket.assigns.form_password))
     |> assign(:form_password2, Map.get(data, "password2", socket.assigns.form_password2))
     |> assign(:errors, validate(data, socket.assigns.mode, socket.assigns.users, socket.assigns.editing))}
  end

  @impl true
  def handle_event("save", %{"user" => data}, socket) do
    errors = validate(data, socket.assigns.mode, socket.assigns.users, socket.assigns.editing)

    if errors == %{} do
      username =
        case socket.assigns.mode do
          :new -> data["username"]
          :edit -> socket.assigns.editing
        end

      case ConfigLoader.upsert_user(username, data) do
        :ok ->
          {:noreply,
           socket
           |> assign(:mode, :list)
           |> assign(:flash_msg, {:ok, "Usuario '#{username}' guardado."})}

        {:error, reason} ->
          {:noreply, assign(socket, :flash_msg, {:error, "Error: #{reason}"})}
      end
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"username" => username}, socket) do
    {:noreply, assign(socket, :confirm_delete, username)}
  end

  @impl true
  def handle_event("delete", %{"username" => username}, socket) do
    case ConfigLoader.delete_user(username) do
      :ok ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> assign(:flash_msg, {:ok, "Usuario '#{username}' eliminado."})}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, {:error, "Error: #{reason}"})}
    end
  end

  @impl true
  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  # --- validation ---

  defp validate(data, mode, users, editing) do
    errors = %{}

    errors =
      if mode == :new do
        username = String.trim(data["username"] || "")

        cond do
          username == "" ->
            Map.put(errors, :username, "Requerido")

          not Regex.match?(~r/^[a-zA-Z0-9_.-]+$/, username) ->
            Map.put(errors, :username, "Solo letras, números, _, - y .")

          Map.has_key?(users, username) ->
            Map.put(errors, :username, "Ya existe un usuario con ese nombre")

          true ->
            errors
        end
      else
        errors
      end

    password = data["password"] || ""
    password2 = data["password2"] || ""

    errors =
      cond do
        mode == :new and password == "" ->
          Map.put(errors, :password, "Requerido")

        password != "" and byte_size(password) < 6 ->
          Map.put(errors, :password, "Mínimo 6 caracteres")

        password != "" and password != password2 ->
          Map.put(errors, :password2, "Las contraseñas no coinciden")

        mode == :edit and password == "" and editing != nil ->
          errors

        true ->
          errors
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
          if(elem(@flash_msg, 0) == :ok,
            do: "bg-emerald-900 text-emerald-300 border border-emerald-700",
            else: "bg-red-900 text-red-300 border border-red-700")
        ]}>
          <%= elem(@flash_msg, 1) %>
          <button phx-click="dismiss_flash" class="ml-2 opacity-70 hover:opacity-100">✕</button>
        </div>
      <% end %>

      <div class="max-w-2xl mx-auto p-6">

        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-xl font-bold">Usuarios</h1>
          <%= if @mode == :list do %>
            <button
              phx-click="new"
              class="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-500 rounded text-sm font-medium transition-colors"
            >
              + Agregar
            </button>
          <% end %>
        </div>

        <%!-- Info si no hay autenticación activa --%>
        <%= if Babel.ConfigLoader.auth_mode() == :none do %>
          <div class="bg-yellow-900/30 border border-yellow-700/50 text-yellow-400 text-xs px-4 py-3 rounded-lg mb-6">
            Sin autenticación activa. Al agregar usuarios, el login pasará a modo usuario/contraseña.
          </div>
        <% end %>

        <%!-- Formulario Nuevo / Editar --%>
        <%= if @mode != :list do %>
          <div class="bg-zinc-900 border border-zinc-700 rounded-lg p-5 mb-6">
            <h2 class="text-sm font-semibold text-zinc-400 mb-4">
              <%= if @mode == :new, do: "Nuevo usuario", else: "Cambiar contraseña — #{@editing}" %>
            </h2>

            <form phx-change="validate" phx-submit="save">
              <%= if @mode == :new do %>
                <.field label="Usuario" name="user[username]" value={@form_username}
                  error={@errors[:username]} placeholder="ej: admin" />
              <% end %>

              <.field label={if @mode == :new, do: "Contraseña", else: "Nueva contraseña"}
                name="user[password]" value={@form_password}
                error={@errors[:password]}
                placeholder={if @mode == :edit, do: "Dejar vacío para no cambiar", else: "Mínimo 6 caracteres"}
                type="password" />

              <.field label="Confirmar contraseña" name="user[password2]" value={@form_password2}
                error={@errors[:password2]} placeholder="Repite la contraseña" type="password" />

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

        <%!-- Lista de usuarios --%>
        <div class="bg-zinc-900 border border-zinc-800 rounded-lg overflow-hidden">
          <%= if map_size(@users) == 0 do %>
            <div class="p-8 text-center text-zinc-600 text-sm">
              No hay usuarios configurados.
            </div>
          <% else %>
            <table class="w-full text-sm">
              <thead>
                <tr class="text-xs text-zinc-500 uppercase tracking-wider border-b border-zinc-800">
                  <th class="text-left px-4 py-3">Usuario</th>
                  <th class="px-4 py-3"></th>
                </tr>
              </thead>
              <tbody>
                <%= for {username, _user} <- Enum.sort(@users) do %>
                  <tr class="border-t border-zinc-800 hover:bg-zinc-800/40">
                    <td class="px-4 py-3 font-semibold text-zinc-200">
                      <%= username %>
                    </td>
                    <td class="px-4 py-3 text-right whitespace-nowrap">
                      <%= if @confirm_delete == username do %>
                        <span class="text-xs text-zinc-400 mr-2">¿Eliminar?</span>
                        <button phx-click="delete" phx-value-username={username}
                          class="text-xs text-red-400 hover:text-red-300 mr-2 font-medium">
                          Sí
                        </button>
                        <button phx-click="cancel"
                          class="text-xs text-zinc-500 hover:text-zinc-300">No</button>
                      <% else %>
                        <button phx-click="edit" phx-value-username={username}
                          class="text-xs text-zinc-400 hover:text-white mr-3 transition-colors">
                          Cambiar contraseña
                        </button>
                        <button phx-click="confirm_delete" phx-value-username={username}
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
end
