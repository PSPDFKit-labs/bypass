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
          pass: false,
          exited: nil,
          error: nil
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
          raise ExUnit.AssertionError, "plug already installed for #{method} #{path}"
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
      when expect in [:expect, :expect_once]
      and method in ["GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "CONNECT", :any]
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
            end
          ))
        _ ->
          raise ExUnit.AssertionError, "Route already installed for #{method}, #{path}"
      end

    {:reply, :ok, %{state | expectations: updated_expectations}}
  end

  defp do_handle_call(
    {expect, _, _, _}, _from, state)
      when expect in [:expect, :expect_once]
  do
    raise ExUnit.AssertionError, "Route for #{expect} does not conform to specification"
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
      |> dispatch_awaiting_caller()

    {:reply, :ok, %{updated_state | pass: true}}
  end

  defp do_handle_call({:get_expect_fun, {method, path}}, _from, state) do
    {route, route_expectations} = route_info(method, path, state)
    case route_expectations do
      nil ->
        expectations = new_route(nil, :never)
        updated_expectations = Map.put(state.expectations, route, expectations)
        {:reply, expectations.fun, %{state | expectations: updated_expectations}}
      _ ->
        {:reply, route_expectations.fun, state}
    end
  end

  defp do_handle_call({:put_expect_result, _, _, {:exit, trace}}, _from, state) do
    {:reply, :ok, %{state | exited: trace}}
  end

  defp do_handle_call({:put_expect_result, route, ref, result}, _from, state) do
    updated_state =
      put_result(route, ref, result, state)
      |> dispatch_awaiting_caller()
    {:reply, :ok, updated_state}
  end

  defp do_handle_call(:on_exit, _from, %{exited: exited, error: error} = state) do
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
        exited ->
          {:exit, exited}
        error ->
          {:error, error}
        true ->
          case expectation_problem_messages(state.expectations) do
            [] -> :ok
            messages -> {:error, :unexpected_count, Enum.join(messages, " ")}
          end
      end

    {:stop, :normal, result, updated_state}
  end

  defp put_result(route, ref, result, state) do
    update_in(state[:expectations][route], fn route_expectations ->
      plugs = Map.fetch!(route_expectations, :retained_plugs)
      Map.merge(route_expectations, %{
        retained_plugs: Map.delete(plugs, ref),
        results: [result | Map.fetch!(route_expectations, :results)]
      })
    end)
  end

  defp expectation_problem_messages(expectations) do
    expectations
    |> expectation_problems
    |> Enum.map(fn {route, expectation, count} ->
         route_id =
           case route do
             {:any, :any} -> case expectation do
               :never -> "bypass"
               _ -> "passed function"
             end
             {method, path} -> "#{method} #{path}"
           end

        expectation_explanation =
          case expectation do
            :once -> "to be called only once"
            :once_or_more -> "to be called at least once"
            :never -> "to never be called"
          end

         count_problem(route_id, expectation_explanation, count)
       end)
  end

  defp count_problem(route, expected, actual_count) do
    times =
      case actual_count do
        1 -> "time"
        _ -> "times"
      end
    "Expected #{route} #{expected}, called #{actual_count} #{times}"
  end

  defp expectation_problems(expectations) do
    expectations
    |> route_expectations_and_counts
    |> Enum.filter(fn {_, expectation, count} ->
         case expectation do
           :once -> count != 1
           :once_or_more -> count == 0
           :never -> count > 0
         end
      end)
  end

  defp route_expectations_and_counts(expectations) do
    expectations
    |> Enum.map(fn {route, expectations} ->
         {route, expectations.expected, length(expectations.results)} end)
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
    %{callers_awaiting_down: callers, socket: socket, ref: ref} = state)
  do
    if retained_plugs_count(state) == 0 and length(callers) > 0 do
      do_down(ref, socket)
      Enum.each(callers, &(GenServer.reply(&1, :ok)))
      %{state | socket: nil, callers_awaiting_down: []}
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
    }
  end
end
