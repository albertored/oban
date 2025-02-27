defmodule Oban.Notifier do
  @moduledoc false

  # The notifier has several different responsibilities and some nuanced behavior:
  #
  # On Start:
  # 1. Create a connection
  # 2. Listen for insert/signal events
  # 3. If connection fails then log the error, break the circuit, and attempt to connect later
  #
  # On Exit:
  # 1. Trip the circuit breaker
  # 2. Schedule a reconnect with backoff
  #
  # On Listen:
  # 1. Put the producer into the listeners map
  # 2. Monitor the pid so that we can clean up if the producer dies
  #
  # On Notification:
  # 1. Iterate through the listeners and forward the message
  # 2. Possibly debounce by event type, on the leading edge, every 50ms?

  use GenServer

  import Oban.Breaker, only: [trip_circuit: 2]

  alias Oban.Config
  alias Postgrex.Notifications

  @type option :: {:name, module()} | {:conf, Config.t()}
  @type channel :: :gossip | :insert | :signal | :update
  @type queue :: atom()

  @mappings %{
    gossip: "oban_gossip",
    insert: "oban_insert",
    signal: "oban_signal",
    update: "oban_update"
  }

  defmodule State do
    @moduledoc false

    @enforce_keys [:conf]
    defstruct [
      :conf,
      :conn,
      circuit: :enabled,
      circuit_backoff: :timer.seconds(30),
      listeners: %{}
    ]
  end

  defmacro gossip, do: @mappings[:gossip]
  defmacro insert, do: @mappings[:insert]
  defmacro signal, do: @mappings[:signal]
  defmacro update, do: @mappings[:update]

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts[:conf], name: name)
  end

  @spec listen(module()) :: :ok
  def listen(server) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :listen)
  end

  @impl GenServer
  def init(%Config{} = conf) do
    Process.flag(:trap_exit, true)

    {:ok, %State{conf: conf}, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    {:noreply, connect_and_listen(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{listeners: listeners} = state) do
    {:noreply, %{state | listeners: Map.delete(listeners, pid)}}
  end

  def handle_info({:notification, _, _, prefixed_channel, payload}, state) do
    [_prefix, channel] = String.split(prefixed_channel, ".")

    decoded = Jason.decode!(payload)

    for {pid, _ref} <- state.listeners, do: send(pid, {:notification, channel, decoded})

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, error}, %State{} = state) do
    {:noreply, trip_circuit(error, state)}
  end

  def handle_info(:reset_circuit, %State{circuit: :disabled} = state) do
    {:noreply, connect_and_listen(state)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:listen, {pid, _}, %State{listeners: listeners} = state) do
    if Map.has_key?(listeners, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      {:reply, :ok, %{state | listeners: Map.put(listeners, pid, ref)}}
    end
  end

  defp connect_and_listen(%State{conf: conf} = state) do
    with {:ok, conn} <- Notifications.start_link(conf.repo.config()),
         {:ok, _ref} <- Notifications.listen(conn, "#{conf.prefix}.#{gossip()}"),
         {:ok, _ref} <- Notifications.listen(conn, "#{conf.prefix}.#{insert()}"),
         {:ok, _ref} <- Notifications.listen(conn, "#{conf.prefix}.#{signal()}") do
      %{state | conn: conn, circuit: :enabled}
    else
      {:error, error} -> trip_circuit(error, state)
    end
  end
end
