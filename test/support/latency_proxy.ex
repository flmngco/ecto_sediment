defmodule EctoSediment.LatencyProxy do
  @moduledoc false
  # A TCP proxy that delays every chunk sent to the upstream server, to test
  # behaviour against a slow S3 endpoint. Set down, it drops the open
  # connections (clients keep HTTP connections alive) and closes every new one
  # at once, like an unreachable endpoint.

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def port(proxy), do: GenServer.call(proxy, :port)
  def set_delay(proxy, ms), do: GenServer.call(proxy, {:set_delay, ms})
  def set_down(proxy, down?), do: GenServer.call(proxy, {:set_down, down?})

  @impl true
  def init(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    # index 1: delay in ms; index 2: 1 while down
    delay = :atomics.new(2, [])
    :atomics.put(delay, 1, Keyword.get(opts, :delay_ms, 0))
    upstream = Keyword.fetch!(opts, :upstream)
    proxy = self()
    spawn_link(fn -> accept(listen, upstream, delay, proxy) end)
    {:ok, %{port: port, delay: delay, pipes: []}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:set_delay, ms}, _from, state) do
    :atomics.put(state.delay, 1, ms)
    {:reply, :ok, state}
  end

  def handle_call({:set_down, down?}, _from, state) do
    :atomics.put(state.delay, 2, if(down?, do: 1, else: 0))
    # A pipe owns its sockets: killing it closes them
    if down?, do: Enum.each(state.pipes, &Process.exit(&1, :kill))
    {:reply, :ok, %{state | pipes: if(down?, do: [], else: state.pipes)}}
  end

  @impl true
  def handle_cast({:pipes, pids}, state),
    do:
      {:noreply, %{state | pipes: pids ++ Enum.filter(state.pipes, &Process.alive?/1)}}

  defp accept(listen, upstream, delay, proxy) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        if :atomics.get(delay, 2) == 1,
          do: :gen_tcp.close(client),
          else: connect(client, upstream, delay, proxy)

      {:error, _} ->
        :ok
    end

    accept(listen, upstream, delay, proxy)
  end

  # Clients may disappear at any moment (the torture test kills them), so
  # failures only close the connection
  defp connect(client, {host, port}, delay, proxy) do
    case :gen_tcp.connect(host, port, [:binary, active: false]) do
      {:ok, server} ->
        pid = spawn(fn -> pipe(client, server, delay) end)
        back = spawn(fn -> pipe(server, client, nil) end)
        _ = :gen_tcp.controlling_process(client, pid)
        _ = :gen_tcp.controlling_process(server, back)
        GenServer.cast(proxy, {:pipes, [pid, back]})

      {:error, _} ->
        :gen_tcp.close(client)
    end
  end

  defp pipe(from, to, delay) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        if delay, do: Process.sleep(:atomics.get(delay, 1))
        :gen_tcp.send(to, data)
        pipe(from, to, delay)

      {:error, _} ->
        :gen_tcp.close(to)
    end
  end
end
