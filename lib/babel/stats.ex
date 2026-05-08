defmodule Babel.Stats do
  use GenServer

  @max_recent 50

  defstruct total: 0, recent: []

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def record(attrs) do
    GenServer.cast(__MODULE__, {:record, attrs})
  end

  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:record, attrs}, state) do
    entry =
      attrs
      |> Map.put(:id, System.unique_integer([:positive, :monotonic]))
      |> Map.put(:at, DateTime.utc_now())

    recent = [entry | state.recent] |> Enum.take(@max_recent)
    new_state = %{state | total: state.total + 1, recent: recent}

    Phoenix.PubSub.broadcast(Babel.PubSub, "babel:stats", {:stats_updated, new_state})

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
end
