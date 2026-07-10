defmodule Bypass.Instance do
  @moduledoc false

  use GenServer, restart: :transient

  import Bypass.Utils
  import Plug.Router.Utils, only: [build_path_match: 1]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [opts])
  end

  def call(pid, request) do
    debug_log("call(#{inspect(pid)}, #{inspect(request)})")
    result = GenServer.call(pid, request, :infinity)
    debug_log("#{inspect(pid)} -> #{inspect(result)}")
    result
  end

  def cast(pid, request) do
    GenServer.cast(pid, request)
  end

  # GenServer callbacks

  def init([opts]) do
    adapter = Application.get_env(:bypass, :adapter, Bypass.Adapter.Bandit)

    # Get a free port from the OS
    case :gen_tcp.listen(Keyword.get(opts, :port, 0), so_reuseport() ++ [ip: listen_ip()]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :erlang.port_close(socket)

        server = do_up(port, adapter)

        state = %{
          expectations: %{},
          port: port,
          adapter: adapter,
          server: server,
          callers_awaiting_down: [],
          callers_awaiting_exit: [],
          pass: false,
          unknown_route_error: nil,
          monitors: %{}
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_info({:DOWN, ref, _, _, reason}, state) do
    case pop_in(state.monitors[ref]) do
      {nil, state} ->
        {:noreply, state}

      {route, state} ->
        result = {:exit, {:exit, reason, []}}
        {:noreply, route |> put_result(ref, result, state) |> dispatch_awaiting_callers()}
    end
  end

  def handle_cast({:put_expect_result, route, ref, result}, state) do
    {:noreply, route |> put_result(ref, result, state) |> dispatch_awaiting_callers()}
  end

  def handle_call(request, from, state) do
    debug_log([inspect(self()), " called ", inspect(request), " with state ", inspect(state)])
    do_handle_call(request, from, state)
  end

  defp do_handle_call(:port, _, %{port: port} = state) do
    {:reply, port, state}
  end

  defp do_handle_call(:up, _from, %{port: port, adapter: adapter, server: nil} = state) do
    server = do_up(port, adapter)
    {:reply, :ok, %{state | server: server}}
  end

  defp do_handle_call(:up, _from, state) do
    {:reply, {:error, :already_up}, state}
  end

  defp do_handle_call(:down, _from, %{server: nil} = state) do
    {:reply, {:error, :already_down}, state}
  end

  defp do_handle_call(
         :down,
         from,
         %{server: server, adapter: adapter, callers_awaiting_down: callers_awaiting_down} = state
       )
       when not is_nil(server) do
    if retained_plugs_count(state) > 0 do
      # wait for plugs to finish
      {:noreply, %{state | callers_awaiting_down: [from | callers_awaiting_down]}}
    else
      do_down(server, adapter)
      {:reply, :ok, %{state | server: nil}}
    end
  end

  defp do_handle_call({expect, fun}, from, state) when expect in [:expect, :expect_once] do
    do_handle_call({expect, :any, :any, fun}, from, state)
  end

  defp do_handle_call({:expect, n, fun}, from, state) do
    do_handle_call({{:exactly, n}, :any, :any, fun}, from, state)
  end

  defp do_handle_call(
         {expect, method, path, fun},
         _from,
         %{expectations: expectations} = state
       )
       when (expect in [:stub, :expect, :expect_once] or
               (is_tuple(expect) and elem(expect, 0) == :exactly)) and
              method in [
                "GET",
                "POST",
                "HEAD",
                "PUT",
                "PATCH",
                "DELETE",
                "OPTIONS",
                "CONNECT",
                :any
              ] and
              (is_binary(path) or path == :any) and
              is_function(fun, 1) do
    route = {method, path}

    updated_expectations =
      Map.put(
        expectations,
        route,
        new_route(
          fun,
          path,
          case expect do
            :expect -> :once_or_more
            :expect_once -> :once
            :stub -> :none_or_more
            {:exactly, n} -> {:exactly, n}
          end
        )
      )

    {:reply, :ok, %{state | expectations: updated_expectations}}
  end

  defp do_handle_call({expect, _, _, _}, _from, _state)
       when expect in [:expect, :expect_once] do
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
         {:get_expect_fun, route},
         from,
         %{expectations: expectations} = state
       ) do
    case Map.get(expectations, route) do
      %{expected: :once, request_count: count} when count > 0 ->
        {:reply, {:error, :too_many_requests, route}, increase_route_count(state, route)}

      %{expected: {:exactly, n}, request_count: count} when count >= n ->
        {:reply, {:error, {:unexpected_request_number, n, count + 1}, route},
         increase_route_count(state, route)}

      nil ->
        {:reply, {:error, :unexpected_request, route}, state}

      route_expectations ->
        state = increase_route_count(state, route)
        {ref, state} = retain_plug_process(route, from, state)
        {:reply, {:ok, ref, route_expectations.fun}, state}
    end
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
        %{server: nil} ->
          state

        %{server: server, adapter: adapter} ->
          do_down(server, adapter)
          %{state | server: nil}
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
    if state.expectations[route] do
      {_, state} = pop_in(state.monitors[ref])

      update_in(state.expectations[route], fn route_expectations ->
        plugs = route_expectations.retained_plugs

        Map.merge(route_expectations, %{
          retained_plugs: Map.delete(plugs, ref),
          results: [result | Map.fetch!(route_expectations, :results)]
        })
      end)
    else
      Map.put(state, :unknown_route_error, result)
    end
  end

  defp increase_route_count(state, route) do
    update_in(
      state.expectations[route],
      fn route_expectations -> Map.update(route_expectations, :request_count, 1, &(&1 + 1)) end
    )
  end

  defp expectation_problem_message(expectations) do
    problem_route =
      expectations
      |> Enum.reject(fn {_route, expectations} -> expectations[:expected] == :none_or_more end)
      |> Enum.find(fn {_route, expectations} -> problem_route?(expectations) end)

    case problem_route do
      {route, %{expected: {:exactly, expected}, request_count: actual}} ->
        {:error, {:unexpected_request_number, expected, actual}, route}

      {route, _} ->
        {:error, :not_called, route}

      nil ->
        Enum.reduce_while(expectations, nil, fn {_route, route_expectations}, _ ->
          first_error =
            Enum.find(route_expectations.results, fn
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

  defp problem_route?(%{expected: {:exactly, n}} = expectations) do
    length(expectations.results) < n
  end

  defp problem_route?(expectations) do
    Enum.empty?(expectations.results)
  end

  defp route_info(method, path, %{expectations: expectations} = _state) do
    segments = build_path_match(path) |> elem(1)

    route =
      expectations
      |> Enum.reduce_while(
        {:any, :any, %{}},
        fn
          {{^method, path_pattern}, %{path_parts: path_parts}}, acc ->
            case match_route(segments, path_parts) do
              {true, params} -> {:halt, {method, path_pattern, params}}
              {false, _} -> {:cont, acc}
            end

          _, acc ->
            {:cont, acc}
        end
      )

    {route, Map.get(expectations, route)}
  end

  defp match_route(path, route) when length(path) == length(route) do
    path
    |> Enum.zip(route)
    |> Enum.reduce_while(
      {true, %{}},
      fn
        {value, {param, _, _}}, {_, params} ->
          {:cont, {true, Map.put(params, Atom.to_string(param), value)}}

        {segment, segment}, acc ->
          {:cont, acc}

        _, _ ->
          {:halt, {false, nil}}
      end
    )
  end

  defp match_route(_, _), do: {false, nil}

  defp do_up(port, adapter) do
    plug_opts = [bypass_instance: self()]

    opts = [
      ref: make_ref(),
      listen_ip: listen_ip(),
      num_acceptors: 5,
      reuseport_raw: so_reuseport()
    ]

    {:ok, server} = adapter.start(Bypass.Plug, plug_opts, port, opts)
    server
  end

  defp do_down(server, adapter) do
    :ok = adapter.stop(server)
  end

  defp retain_plug_process({method, path} = route, {caller_pid, _}, state) do
    debug_log([
      inspect(self()),
      " retain_plug_process ",
      inspect(caller_pid),
      ", retained_plugs: ",
      inspect(
        Map.get(state.expectations, route)
        |> Map.get(:retained_plugs)
        |> Map.values()
      )
    ])

    ref = Process.monitor(caller_pid)

    state =
      update_in(state.expectations[route][:retained_plugs], fn plugs ->
        Map.update(plugs, ref, caller_pid, fn _ ->
          raise "plug already installed for #{method} #{path}"
        end)
      end)

    {ref, put_in(state.monitors[ref], route)}
  end

  defp dispatch_awaiting_callers(
         %{
           callers_awaiting_down: down_callers,
           callers_awaiting_exit: exit_callers,
           server: server,
           adapter: adapter
         } = state
       ) do
    if retained_plugs_count(state) == 0 do
      down_reset =
        if length(down_callers) > 0 do
          do_down(server, adapter)
          Enum.each(down_callers, &GenServer.reply(&1, :ok))
          %{state | server: nil, callers_awaiting_down: []}
        end

      if length(exit_callers) > 0 do
        {result, _updated_state} = do_exit(state)
        Enum.each(exit_callers, &GenServer.reply(&1, result))
        GenServer.stop(:normal)
      end

      down_reset || state
    else
      state
    end
  end

  defp retained_plugs_count(state) do
    state.expectations
    |> Map.values()
    |> Enum.flat_map(&Map.get(&1, :retained_plugs))
    |> length
  end

  defp new_route(fun, path_parts, expected) when is_list(path_parts) do
    %{
      fun: fun,
      expected: expected,
      path_parts: path_parts,
      retained_plugs: %{},
      results: [],
      request_count: 0
    }
  end

  defp new_route(fun, :any, expected) do
    new_route(fun, [], expected)
  end

  defp new_route(fun, path, expected) do
    new_route(fun, build_path_match(path) |> elem(1), expected)
  end

  # This is used to override the default behaviour of ranch_tcp
  # and limit the range of interfaces it will listen on to just
  # the configured interface. Loopback is a default interface.
  defp listen_ip do
    case Application.get_env(:bypass, :listen_ip, {127, 0, 0, 1}) do
      listen_ip when is_tuple(listen_ip) ->
        listen_ip

      listen_ip ->
        listen_ip
        |> to_charlist()
        |> :inet.parse_address()
        |> case do
          {:ok, listen_ip} ->
            listen_ip

          {:error, :einval} ->
            raise ArgumentError, "invalid listen_ip: #{inspect(listen_ip)}"
        end
    end
  end
end
