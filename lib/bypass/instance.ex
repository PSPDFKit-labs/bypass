defmodule Bypass.Instance do
  use GenServer

  require Logger

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

  def call(pid, request) do
    if Bypass.debug_log_enabled?,
      do: Logger.debug "[Bypass.Instance] call(#{inspect pid}, #{inspect request})"
    result = GenServer.call(pid, request, :infinity)
    if Bypass.debug_log_enabled?,
      do: Logger.debug "[Bypass.Instance] #{inspect pid} -> #{inspect result}"
    result
  end

  def cast(pid, request) do
    GenServer.cast(pid, request)
  end

  # GenServer callbacks

  def init([parent]) do
    Logger.debug "[Bypass.Instance] init([#{inspect parent}])"

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
      retained_plug: nil,
      caller_awaiting_down: nil,
    }

    send(parent, {:bypass_port, self(), port})

    {:ok, state}
  end

  def handle_call(request, from, state) do
    if Bypass.debug_log_enabled? do
      Logger.debug [
        "[Bypass.Instance] ", inspect(self()),
        " called ", inspect(request), " with state ", inspect(state)
      ]
    end
    do_handle_call(request, from, state)
  end

  def handle_cast({:retain_plug_process, caller_pid}, state) do
    if Bypass.debug_log_enabled? do
      Logger.debug [
        "[Bypass.Instance] ", inspect(self()), " retain_plug_process ", inspect(caller_pid),
        ", retained_plug: ", inspect(state.retained_plug)
      ]
    end
    {:noreply, Map.update!(state, :retained_plug, fn nil -> caller_pid end)}
  end

  defp do_handle_call(:up, _from, %{port: port, ref: ref, socket: nil} = state) do
    socket = do_up(port, ref)
    {:reply, :ok, %{state | socket: socket}}
  end
  defp do_handle_call(:up, _from, state) do
    {:reply, {:error, :already_up}, state}
  end

  defp do_handle_call(:down, _from, %{socket: nil} = state) do
    {:reply, {:error, :already_down}, state}
  end
  defp do_handle_call(:down, from, %{socket: socket, ref: ref} = state) when not is_nil(socket) do
    nil = state.caller_awaiting_down  # assertion
    if state.retained_plug != nil do
      # wait for the plug to finish
      {:noreply, %{state | caller_awaiting_down: from}}
    else
      do_down(ref, socket)
      {:reply, :ok, %{state | socket: nil}}
    end
  end

  defp do_handle_call({:expect, nil}, _from, state) do
    {:reply, :ok, %{state | expect_fun: nil, request_result: :ok}}
  end
  defp do_handle_call({:expect, fun}, _from, state) do
    {:reply, :ok, %{state | expect_fun: fun, request_result: {:error, :not_called}}}
  end

  defp do_handle_call(:get_expect_fun, _from, %{expect_fun: expect_fun} = state) do
    {:reply, expect_fun, state}
  end

  defp do_handle_call({:put_expect_result, result}, _from, state) do
    updated_state =
      %{state | request_result: result}
      |> Map.put(:retained_plug, nil)
      |> dispatch_awaiting_caller()
    {:reply, :ok, updated_state}
  end

  defp do_handle_call(:on_exit, _from, state) do
    updated_state =
      case state do
        %{socket: nil} -> state
        %{socket: socket, ref: ref} ->
          do_down(ref, socket)
          %{state | socket: nil}
      end
    {:stop, :normal, state.request_result, updated_state}
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

  defp dispatch_awaiting_caller(
    %{retained_plug: retained_plug, caller_awaiting_down: caller, socket: socket, ref: ref} = state)
  do
    if retained_plug == nil and caller != nil do
      do_down(ref, socket)
      GenServer.reply(caller, :ok)
      %{state | socket: nil, caller_awaiting_down: nil}
    else
      state
    end
  end
end
