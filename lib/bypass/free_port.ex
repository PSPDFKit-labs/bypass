defmodule Bypass.FreePort do
  alias Bypass.Utils
  use GenServer

  defstruct [:ports, :owners]

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def reserve(owner) do
    GenServer.call(__MODULE__, {:reserve, owner})
  end

  def init([]) do
    {:ok, %__MODULE__{ports: MapSet.new(), owners: %{}}}
  end

  def handle_call({:reserve, owner}, _from, state) do
    ref = Process.monitor(owner)
    {state, reply} = find_free_port(state, owner, ref, 0)
    {:reply, reply, state}
  end

  def handle_info({:DOWN, ref, _type, pid, _reason}, state) do
    state =
      case Map.pop(state.owners, {pid, ref}) do
        {nil, _} ->
          state

        {port, owners} ->
          %{state | ports: MapSet.delete(state.ports, port), owners: owners}
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp find_free_port(state, _owner, _ref, 10 = _attempt),
    do: {state, {:error, :too_many_attempts}}

  defp find_free_port(state, owner, ref, attempt) do
    case :ranch_tcp.listen(Utils.so_reuseport() ++ [ip: Utils.listen_ip(), port: 0]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)

        if MapSet.member?(state.ports, port) do
          true = :erlang.port_close(socket)

          find_free_port(state, owner, ref, attempt + 1)
        else
          state = %{
            state
            | ports: MapSet.put(state.ports, port),
              owners: Map.put_new(state.owners, {owner, ref}, port)
          }

          {state, {:ok, socket}}
        end

      {:error, reason} ->
        {state, {:error, reason}}
    end
  end
end
