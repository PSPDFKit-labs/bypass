defmodule Bypass.Instance do
  use GenServer

  import Bypass.Utils

  # This is used to override the default behaviour of ranch_tcp
  # and limit the range of interfaces it will listen on to just
  # the loopback interface.
  @listen_ip {127, 0, 0, 1}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [opts])
  end

  def call(pid, request) do
    debug_log "call(#{inspect pid}, #{inspect request})"
    result = GenServer.call(pid, request, :infinity)
    debug_log "#{inspect pid} -> #{inspect result}"
    result
  end

  def cast(pid, request) do
    GenServer.cast(pid, request)
  end

  # GenServer callbacks

  def init([opts]) do
    # Get a free port from the OS
    case :ranch_tcp.listen(ip: @listen_ip, port: Keyword.get(opts, :port, 0)) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :erlang.port_close(socket)

        ref = make_ref()
        socket = do_up(port, ref)

        state = %{
          expectations: %{},
          port: port,
          ref: ref,
          socket: socket,
          callers_awaiting_down: [],
          callers_awaiting_exit: [],
          pass: false,
          unknown_route_error: nil
        }

        {:ok, state}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call(request, from, state) do
    debug_log [inspect(self()), " called ", inspect(request), " with state ", inspect(state)]
    do_handle_call(request, from, state)
  end

  def handle_cast({:retain_plug_process, {method, path} = route, ref, caller_pid}, state) do
    debug_log [
      inspect(self()), " retain_plug_process ", inspect(caller_pid),
      ", retained_plugs: ", inspect(
        Map.get(state.expectations, route)
        |> Map.get(:retained_plugs)
        |> Map.values
      )
    ]

    updated_state =
      update_in(state[:expectations][route][:retained_plugs], fn plugs ->
        Map.update(plugs, ref, caller_pid, fn _ ->
          raise "plug already installed for #{method} #{path}"
        end)
      end)

    {:noreply, updated_state}
  end

  defp do_handle_call(:port, _, %{port: port} = state) do
    {:reply, port, state}
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
  defp do_handle_call(:down, from, %{socket: socket, ref: ref, callers_awaiting_down: callers_awaiting_down} = state) when not is_nil(socket) do
    if retained_plugs_count(state) > 0 do
      # wait for plugs to finish
      {:noreply, %{state | callers_awaiting_down: [from | callers_awaiting_down]}}
    else
      do_down(ref, socket)
      {:reply, :ok, %{state | socket: nil}}
    end
  end

  defp do_handle_call({expect, fun}, from, state) when expect in [:expect, :expect_once] do
    do_handle_call({expect, :any, :any, fun}, from, state)
  end

  defp do_handle_call(
    {expect, method, path, fun}, _from, %{expectations: expectations} = state)
      when expect in [:stub, :expect, :expect_once]
      and method in ["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", :any]
      and (is_binary(path) or path == :any)
      and is_function(fun, 1)
  do
    route = {method, path}

    updated_expectations =
      case Map.get(expectations, route, :none) do
        :none ->
          Map.put(expectations, route, new_route(
            fun,
            case expect do
              :expect -> :once_or_more
              :expect_once -> :once
              :stub -> :none_or_more
            end
          ))
        _ ->
          raise "Route already installed for #{method}, #{path}"
      end

    {:reply, :ok, %{state | expectations: updated_expectations}}
  end

  defp do_handle_call({expect, _, _, _}, _from, _state)
    when expect in [:expect, :expect_once]
  do
    raise "Route for #{expect} does not conform to specification"
  end

  defp do_handle_call({:get_route, method, path}, _from, state) do
    {route, _} = route_info(method, path, state)
    {:reply, route, state}
  end

  defp do_handle_call(:pass, _from, state) do
    updated_state =
      Enum.reduce(state.expectations, state, fn {route, route_expectations}, state_acc ->
        Enum.reduce(route_expectations.retained_plugs, state_acc, fn {ref, _}, plugs_acc ->
          put_result(route, ref, :ok, plugs_acc)
        end)
      end)

    {:reply, :ok, %{updated_state | pass: true}}
  end

  defp do_handle_call(
    {:get_expect_fun, route}, _from, %{expectations: expectations} = state
  ) do
    case Map.get(expectations, route) do
      %{expected: :once, request_count: count} when count > 0 ->
        {:reply, {:error, :too_many_requests, route}, increase_route_count(state, route)}
      nil ->
        {:reply, {:error, :unexpected_request, route}, state}
      route_expectations ->
        {:reply, route_expectations.fun, increase_route_count(state, route)}
    end
  end

  defp do_handle_call({:put_expect_result, route, ref, result}, _from, state) do
    updated_state =
      put_result(route, ref, result, state)
      |> dispatch_awaiting_callers()

    {:reply, :ok, updated_state}
  end

  defp do_handle_call(:on_exit, from, %{callers_awaiting_exit: callers} = state) do
    if retained_plugs_count(state) > 0 do
      {:noreply, %{state | callers_awaiting_exit: [from | callers]}}
    else
      {result, updated_state} = do_exit(state)
      {:stop, :normal, result, updated_state}
    end
  end

  defp do_exit(state) do
    updated_state =
      case state do
        %{socket: nil} -> state
        %{socket: socket, ref: ref} ->
          do_down(ref, socket)
          %{state | socket: nil}
      end

    result =
      cond do
        state.pass ->
          :ok
        state.unknown_route_error ->
          state.unknown_route_error
        true ->
          case expectation_problem_message(state.expectations) do
            nil -> :ok
            error -> error
          end
      end

    {result, updated_state}
  end

  defp put_result(route, ref, result, state) do
    case get_in(state, [:expectations, route]) do
      nil ->
        Map.put(state, :unknown_route_error, result)
      _ -> update_in(state[:expectations][route], fn route_expectations ->
             plugs = Map.fetch!(route_expectations, :retained_plugs)
             Map.merge(route_expectations, %{
               retained_plugs: Map.delete(plugs, ref),
               results: [result | Map.fetch!(route_expectations, :results)]
             })
           end)
    end
  end

  defp increase_route_count(state, route) do
    update_in(state[:expectations][route],
      fn route_expectations -> Map.update(route_expectations, :request_count, 1, &(&1 + 1)) end)
  end

  defp expectation_problem_message(expectations) do
    problem_route =
      expectations
      |> Enum.reject(fn {_route, expectations} -> expectations[:expected] == :none_or_more end)
      |> Enum.find(fn {_route, expectations} -> length(expectations.results) == 0 end)

    case problem_route do
      {route, _} -> {:error, :not_called, route}
      nil -> Enum.reduce_while(expectations, nil, fn {_route, route_expectations}, _ ->
               first_error = Enum.find(route_expectations.results, fn
                 result when is_tuple(result) -> result
                 _result -> nil
               end)
               case first_error do
                 nil -> {:cont, nil}
                 error -> {:halt, error}
               end
             end)
    end
  end

  defp route_info(method, path, %{expectations: expectations} = _state) do
    route =
      case Map.get(expectations, {method, path}, :no_expectations) do
        :no_expectations ->
          {:any, :any}
        _ ->
          {method, path}
      end

    {route, Map.get(expectations, route)}
  end

  defp do_up(port, ref) do
    plug_opts = [self()]
    {:ok, socket} = :ranch_tcp.listen(ip: @listen_ip, port: port)
    cowboy_opts = [ref: ref, port: port, transport_options: [num_acceptors: 5, socket: socket]]
    {:ok, _pid} = Plug.Cowboy.http(Bypass.Plug, plug_opts, cowboy_opts)
    socket
  end

  defp do_down(ref, socket) do
    :ok = Plug.Cowboy.shutdown(ref)

    # `port_close` is synchronous, so after it has returned we _know_ that the socket has been
    # closed. If we'd rely on ranch's supervisor shutting down the acceptor processes and thereby
    # killing the socket we would run into race conditions where the socket port hasn't yet gotten
    # the EXIT signal and would still be open, thereby breaking tests that rely on a closed socket.
    case :erlang.port_info(socket, :name) do
      :undefined -> :ok
      _ -> :erlang.port_close(socket)
    end
  end

  defp dispatch_awaiting_callers(%{callers_awaiting_down: down_callers,
    callers_awaiting_exit: exit_callers, socket: socket, ref: ref} = state) do

    if retained_plugs_count(state) == 0 do
      down_reset =
        if length(down_callers) > 0 do
          do_down(ref, socket)
          Enum.each(down_callers, &(GenServer.reply(&1, :ok)))
          %{state | socket: nil, callers_awaiting_down: []}
        end

      if length(exit_callers) > 0 do
        {result, _updated_state} = do_exit(state)
        Enum.each(exit_callers, &(GenServer.reply(&1, result)))
        GenServer.stop(:normal)
      end

      down_reset || state
    else
      state
    end
  end

  defp retained_plugs_count(state) do
    state.expectations
    |> Map.values
    |> Enum.flat_map(&(Map.get(&1, :retained_plugs)))
    |> length
  end

  defp new_route(fun, expected) do
    %{
      fun: fun,
      expected: expected,
      retained_plugs: %{},
      results: [],
      request_count: 0
    }
  end
end
