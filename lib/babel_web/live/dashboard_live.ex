defmodule BabelWeb.DashboardLive do
  use BabelWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Babel.PubSub, "babel:stats")

    config = Babel.ConfigLoader.get()
    stats = Babel.Stats.get()

    socket =
      socket
      |> assign(:page_title, "Babel Gateway")
      |> assign(:config, config)
      |> assign(:stats, stats)

    {:ok, socket}
  end

  @impl true
  def handle_info({:stats_updated, stats}, socket) do
    {:noreply, assign(socket, :stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-100 p-6 font-mono">

      <%!-- Header --%>
      <div class="flex items-center justify-between mb-8">
        <div class="flex items-center gap-3">
          <span class="text-2xl font-bold tracking-tight">🗼 Babel</span>
          <span class="text-zinc-500 text-sm">Universal LLM Gateway</span>
        </div>
        <div class="flex items-center gap-2">
          <div class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></div>
          <span class="text-emerald-400 text-sm">live</span>
        </div>
      </div>

      <%!-- Stats bar --%>
      <div class="bg-zinc-900 rounded-lg px-5 py-3 mb-6 flex items-center gap-6 border border-zinc-800">
        <div>
          <span class="text-zinc-500 text-xs uppercase tracking-wider">Total requests</span>
          <p class="text-xl font-bold text-white"><%= @stats.total %></p>
        </div>
        <div class="w-px h-8 bg-zinc-800"></div>
        <div>
          <span class="text-zinc-500 text-xs uppercase tracking-wider">Providers</span>
          <p class="text-xl font-bold text-white"><%= map_size(@config.providers) %></p>
        </div>
        <div class="w-px h-8 bg-zinc-800"></div>
        <div>
          <span class="text-zinc-500 text-xs uppercase tracking-wider">Models</span>
          <p class="text-xl font-bold text-white"><%= map_size(@config.models) %></p>
        </div>
      </div>

      <%!-- Providers + Models grid --%>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">

        <%!-- Providers --%>
        <div class="bg-zinc-900 rounded-lg p-5 border border-zinc-800">
          <h2 class="text-xs uppercase tracking-widest text-zinc-500 mb-3">Providers</h2>
          <%= if map_size(@config.providers) == 0 do %>
            <p class="text-zinc-600 text-sm">No providers configured</p>
          <% else %>
            <div class="space-y-2">
              <%= for {name, provider} <- @config.providers do %>
                <div class="flex items-center justify-between py-2 border-b border-zinc-800 last:border-0">
                  <div class="flex items-center gap-2">
                    <div class="w-1.5 h-1.5 rounded-full bg-emerald-400"></div>
                    <span class="font-semibold text-zinc-200"><%= name %></span>
                  </div>
                  <span class="text-xs text-zinc-500 truncate max-w-[200px]">
                    <%= URI.parse(provider.base_url).host %>
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Models --%>
        <div class="bg-zinc-900 rounded-lg p-5 border border-zinc-800">
          <h2 class="text-xs uppercase tracking-widest text-zinc-500 mb-3">Models</h2>
          <%= if map_size(@config.models) == 0 do %>
            <p class="text-zinc-600 text-sm">No models configured</p>
          <% else %>
            <div class="space-y-2">
              <%= for {name, model} <- @config.models do %>
                <div class="flex items-center justify-between py-2 border-b border-zinc-800 last:border-0">
                  <span class="text-zinc-200 text-sm"><%= name %></span>
                  <span class="text-xs bg-zinc-800 text-zinc-400 px-2 py-0.5 rounded">
                    <%= model.provider %>
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Recent requests --%>
      <div class="bg-zinc-900 rounded-lg p-5 border border-zinc-800">
        <h2 class="text-xs uppercase tracking-widest text-zinc-500 mb-3">Recent Requests</h2>

        <%= if @stats.recent == [] do %>
          <p class="text-zinc-600 text-sm text-center py-6">Waiting for requests...</p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-zinc-600 text-xs uppercase tracking-wider">
                  <th class="text-left pb-2 pr-4">Time</th>
                  <th class="text-left pb-2 pr-4">Model</th>
                  <th class="text-left pb-2 pr-4">Status</th>
                  <th class="text-left pb-2 pr-4">Duration</th>
                  <th class="text-left pb-2">Type</th>
                </tr>
              </thead>
              <tbody>
                <%= for req <- @stats.recent do %>
                  <tr class="border-t border-zinc-800 hover:bg-zinc-800/50">
                    <td class="py-2 pr-4 text-zinc-500 text-xs">
                      <%= Calendar.strftime(req.at, "%H:%M:%S") %>
                    </td>
                    <td class="py-2 pr-4 text-zinc-300 max-w-[180px] truncate">
                      <%= req.model %>
                    </td>
                    <td class="py-2 pr-4">
                      <span class={[
                        "px-1.5 py-0.5 rounded text-xs font-medium",
                        if(req.status < 300, do: "bg-emerald-900/50 text-emerald-400",
                           else: "bg-red-900/50 text-red-400")
                      ]}>
                        <%= req.status %>
                      </span>
                    </td>
                    <td class="py-2 pr-4 text-zinc-400">
                      <%= format_duration(req.duration_ms) %>
                    </td>
                    <td class="py-2 text-zinc-500 text-xs">
                      <%= if req.stream, do: "stream", else: "sync" %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <%!-- Footer --%>
      <div class="mt-6 text-center text-zinc-700 text-xs">
        Babel v0.1.0 · Elixir/<%= System.version() %> · OTP <%= :erlang.system_info(:otp_release) %>
      </div>
    </div>
    """
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
