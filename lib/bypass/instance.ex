defmodule Bypass.Instance do
  use GenServer

  def start_link do
    case GenServer.start_link(__MODULE__, [self()]) do
      {:ok, pid} ->
        port = receive do
          {:bypass_port, ^pid, port} -> port
        end
        {:ok, pid, port}
      {:error, _} = err -> err
    end
  end

  def call(pid, request), do: GenServer.call(pid, request, :infinity)

  # GenServer callbacks

  def init([parent]) do
    # Get a free port from the OS
    {:ok, socket} = :ranch_tcp.listen(port: 0)
    {:ok, port} = :inet.port(socket)
    :erlang.port_close(socket)

    ref = make_ref
    socket = do_up(port, ref)

    state = %{
      expect_fun: nil,
      port: port,
      ref: ref,
      request_result: :ok,
      socket: socket,
    }

    send(parent, {:bypass_port, self(), port})

    {:ok, state}
  end

  def handle_call(:up, _from, %{port: port, ref: ref, socket: nil} = state) do
    socket = do_up(port, ref)
    {:reply, :ok, %{state | socket: socket}}
  end
  def handle_call(:up, _from, state) do
    {:reply, {:error, :already_up}, state}
  end

  def handle_call(:down, _from, %{socket: nil} = state) do
    {:reply, {:error, :already_down}, state}
  end
  def handle_call(:down, _from, %{socket: socket, ref: ref} = state) when not is_nil(socket) do
    do_down(ref, socket)
    {:reply, :ok, %{state | socket: nil}}
  end

  def handle_call({:expect, nil}, _from, state) do
    {:reply, :ok, %{state | expect_fun: nil, request_result: :ok}}
  end
  def handle_call({:expect, fun}, _from, state) do
    {:reply, :ok, %{state | expect_fun: fun, request_result: {:error, :not_called}}}
  end

  def handle_call(:get_expect_fun, _from, %{expect_fun: expect_fun} = state) do
    {:reply, expect_fun, state}
  end

  def handle_call({:put_expect_result, result}, _from, state) do
    {:reply, :ok, %{state | request_result: result}}
  end

  def handle_call(:on_exit, _from, state) do
    state = case state do
      %{socket: nil} -> state
      %{socket: socket, ref: ref} ->
        do_down(ref, socket)
        %{state | socket: nil}
    end

    {:stop, :normal, state.request_result, state}
  end

  defp do_up(port, ref) do
    plug_opts = [self()]
    {:ok, socket} = :ranch_tcp.listen(port: port)
    cowboy_opts = [ref: ref, acceptors: 5, port: port, socket: socket]
    {:ok, _pid} = Plug.Adapters.Cowboy.http(Bypass.Plug, plug_opts, cowboy_opts)
    socket
  end

  defp do_down(ref, socket) do
    :ok = Plug.Adapters.Cowboy.shutdown(ref)

    # `port_close` is synchronous, so after it has returned we _know_ that the socket has been
    # closed. If we'd rely on ranch's supervisor shutting down the acceptor processes and thereby
    # killing the socket we would run into race conditions where the socket port hasn't yet gotten
    # the EXIT signal and would still be open, thereby breaking tests that rely on a closed socket.
    case :erlang.port_info(socket, :name) do
      :undefined -> :ok
      _ -> :erlang.port_close(socket)
    end
  end
end
