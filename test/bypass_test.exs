defmodule BypassTest do
  use ExUnit.Case
  doctest Bypass

  if Code.ensure_loaded?(ExUnit.CaptureLog) do
    defdelegate capture_log(fun), to: ExUnit.CaptureLog
  else
    # Shim capture_log for Elixir 1.0
    defp capture_log(fun) do
      ExUnit.CaptureIO.capture_io(:user, fn ->
        fun.()
        Logger.flush()
      end) |> String.strip
    end
  end

  test "Bypass.expect's fun gets called for every single request" do
    five_requests(:expect)
  end

  test "Bypass.expect_once's fun gets called for each request, with an error reported for too many calls" do
    bypass = five_requests(:expect_once)
    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_count, _} = exit_result
      assert Regex.match?(~r/passed function.+called 5 times/, elem(exit_result, 2))
    end)
  end

  defp five_requests(expect_fun) do
    bypass = Bypass.open
    parent = self()
    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn conn ->
        send(parent, :request_received)
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])
    Enum.each(1..5, fn _ ->
      assert {:ok, 200, ""} = request(bypass.port)
      assert_receive :request_received
    end)
    bypass
  end

  test "Bypass.open can specify a port to operate on with expect" do
    1234 |> specify_port(:expect)
  end

  test "Bypass.open can specify a port to operate on with expect_once" do
    1235 |> specify_port(:expect_once)
  end

  defp specify_port(port, expect_fun) do
    bypass = Bypass.open(port: port)
  
    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn conn ->
        assert port == conn.port
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])
  
    assert {:ok, 200, ""} = request(port)
    assert {:error, :eaddrinuse} == Bypass.open(port: port)
  end

  test "Bypass.down takes down the socket with expect" do
    :expect |> down_socket
  end

  test "Bypass.down takes down the socket with expect_once" do
    :expect_once |> down_socket
  end

  defp down_socket(expect_fun) do
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn conn -> Plug.Conn.send_resp(conn, 200, "") end
    ])
    assert {:ok, 200, ""} = request(bypass.port)

    Bypass.down(bypass)
    assert {:error, :noconnect} = request(bypass.port)
  end

  test "Bypass.up opens the socket again" do
    bypass = Bypass.open
    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)
    assert {:ok, 200, ""} = request(bypass.port)

    Bypass.down(bypass)
    assert {:error, :noconnect} = request(bypass.port)

    Bypass.up(bypass)
    assert {:ok, 200, ""} = request(bypass.port)
  end

  test "Bypass.expect raises if no request is made" do
    :expect |> no_request
  end

  test "Bypass.expect_once raises if no request is made" do
    :expect_once |> no_request
  end

  defp no_request(expect_fun) do
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn _conn -> assert false end
    ])
    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_count, _} = exit_result
      assert Regex.match?(~r/called 0 times/, elem(exit_result, 2))
    end)
  end

  test "Bypass.expect can be canceled by expecting nil" do
    :expect |> cancel
  end

  test "Bypass.expect_once can be canceled by expecting nil" do
    :expect_once |> cancel
  end

  defp cancel(expect_fun) do
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn _conn -> assert false end
    ])
    Bypass.expect(bypass, nil)
  end

  test "Bypass.expect can be made to pass by calling Bypass.pass" do
    :expect |> pass
  end

  test "Bypass.expect_once can be made to pass by calling Bypass.pass" do
    :expect_once |> pass
  end

  defp pass(expect_fun) do
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn _conn ->
        Bypass.pass(bypass)
        Process.exit(self(), :normal)
        assert false
      end
    ])

    capture_log fn ->
      assert {:error, {:closed, 'The connection was lost.'}} = request(bypass.port)
    end
  end

  test "closing a bypass while the request is in-flight with expect" do
    :expect |> closing_in_flight
  end

  test "closing a bypass while the request is in-flight with expect_once" do
    :expect_once |> closing_in_flight
  end

  defp closing_in_flight(expect_fun) do
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn _conn ->
        Bypass.pass(bypass) # mark the request as arrived, since we're shutting it down now
        Bypass.down(bypass)
      end
    ])
    assert {:error, {:closed, 'The connection was lost.'}} == request(bypass.port)
  end

  test "Bypass.down waits for plug process to terminate before shutting it down with expect" do
    :expect |> down_wait_to_terminate
  end

  test "Bypass.down waits for plug process to terminate before shutting it down with expect_once" do
    :expect_once |> down_wait_to_terminate
  end

  defp down_wait_to_terminate(expect_fun) do
    test_process = self()
    ref = make_ref()
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn conn ->
        result = Plug.Conn.send_resp(conn, 200, "")
        :timer.sleep(200)
        send(test_process, ref)
        result
      end
    ])

    assert {:ok, 200, ""} = request(bypass.port)

    # Here we make sure that Bypass.down waits until the plug process finishes its work
    # before shutting down
    refute_received ^ref
    Bypass.down(bypass)
    assert_received ^ref
  end

  test "Conrrent calls to down" do
    test_process = self()
    ref = make_ref()
    bypass = Bypass.open

    Bypass.expect(
      bypass, "POST", "/this",
      fn conn ->
        :timer.sleep(200)
        Plug.Conn.send_resp(conn, 200, "")
      end
    )

    Bypass.expect(
      bypass, "POST", "/that", fn conn ->
        :timer.sleep(200)
        result = Plug.Conn.send_resp(conn, 200, "")
        send(test_process, ref)
        result
      end
    )

    assert {:ok, 200, ""} = request(bypass.port, "/this")

    tasks = Enum.map(1..5, fn _ ->
      Task.async(fn ->
        assert {:ok, 200, ""} = request(bypass.port, "/that")
        Bypass.down(bypass)
      end)
    end)

    # Here we make sure that Bypass.down waits until the plug process finishes its work
    # before shutting down
    refute_received ^ref
    :timer.sleep(200)
    Bypass.down(bypass)

    Enum.map(tasks, fn task ->
      Task.await(task)
      assert_received ^ref
    end)
  end

  test "Calling a bypass route without expecting a call fails the test" do
    bypass = Bypass.open
    capture_log fn ->
      assert {:ok, 500, ""} = request(bypass.port)
    end

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_count, _} = exit_result
      assert Regex.match?(~r/to never be called.+called 1 time/, elem(exit_result, 2))
    end)
  end

  test "Bypass can handle concurrent requests with expect" do
    bypass = concurrent_requests(:expect)
    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      :ok == Bypass.Instance.call(bypass.pid, :on_exit)
    end)
  end

  test "Bypass can handle concurrent requests with expect_once" do
    bypass = concurrent_requests(:expect_once)
    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_count, _} = exit_result
      assert Regex.match?(~r/passed function.+called 5 times/, elem(exit_result, 2))
    end)
  end

  defp concurrent_requests(expect_fun) do
    bypass = Bypass.open
    parent = self()
    apply(Bypass, expect_fun, [
      bypass,
      fn conn ->
        send(parent, :request_received)
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])
    tasks = Enum.map(1..5, fn _ ->
      Task.async(fn -> {:ok, 200, ""} = request(bypass.port) end)
    end)
    Enum.map(tasks, fn task ->
      Task.await(task)
      assert_receive :request_received
    end)
    bypass
  end

  test "Bypass.expect/4 can be used to define a specific route" do
    :expect |> specific_route
  end

  test "Bypass.expect_once/4 can be used to define a specific route" do
    :expect_once |> specific_route
  end

  defp specific_route(expect_fun) do
    bypass = Bypass.open
    method = "POST"
    path = "/this"

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass, method, path, fn conn ->
        assert conn.method == method
        assert conn.request_path == path
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log fn ->
      assert {:ok, 200, ""} = request(bypass.port, path)
    end
  end

  test "Bypass.expect/4 can be used to define multiple paths" do
    :expect |> multiple_paths
  end

  test "Bypass.expect_once/4 can be used to define multiple paths" do
    :expect_once |> multiple_paths
  end

  defp multiple_paths(expect_fun) do
    bypass = Bypass.open
    method = "POST"
    paths = ["/this", "/that"]

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass, method, paths, fn conn ->
        assert conn.method == method
        assert Enum.any?(paths, fn path -> conn.request_path == path end)
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log fn ->
      Enum.each(paths, fn path ->
        assert {:ok, 200, ""} = request(bypass.port, path)
      end)
    end
  end

  test "Bypass.expect/4 can be used to define multiple methods" do
    :expect |> multiple_methods
  end

  test "Bypass.expect_once/4 can be used to define multiple methods" do
    :expect_once |> multiple_methods
  end

  defp multiple_methods(expect_fun) do
    bypass = Bypass.open
    methods = ["POST", "GET"]
    path = "/this"

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass, methods, path, fn conn ->
        assert Enum.any?(methods, fn method -> conn.method == method end)
        assert conn.request_path == path
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log fn ->
      Enum.each(methods, fn method ->
        assert {:ok, 200, ""} =
          request(bypass.port, path, method |> String.downcase |> String.to_atom)
      end)
    end
  end

  test "All routes to a Bypass.expect/4 call must be called" do
    :expect |> all_routes_must_be_called
  end

  test "All routes to a Bypass.expect_once/4 call must be called" do
    :expect_once |> all_routes_must_be_called
  end

  defp all_routes_must_be_called(expect_fun) do
    bypass = Bypass.open
    method = "POST"
    paths = ["/this", "/that"]

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass, method, paths, fn conn ->
        assert conn.method == method
        assert Enum.any?(paths, fn path -> conn.request_path == path end)
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log fn ->
      assert {:ok, 200, ""} = request(bypass.port, "/this")
    end

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_count, _} = exit_result
      assert Regex.match?(~r/POST.+\/that.+called 0 times/, elem(exit_result, 2))
    end)
  end

  @doc ~S"""
  Open a new HTTP connection and perform the request. We don't want to use httpc, hackney or another
  "high-level" HTTP client, since they do connection pooling and we will sometimes get a connection
  closed error and not a failed to connect error, when we test Bypass.down
  """
  def request(port, path \\ "", method \\ :post) do
    {:ok, conn} = :gun.start_link(self(), '127.0.0.1', port, %{retry: 0})
    try do
      case :gun.await_up(conn, 250) do
        {:ok, _protocol} ->
           stream =
             case method do
               :post -> :gun.post(conn, path, [], "")
               :get  -> :gun.get(conn, path, [])
             end

           case :gun.await(conn, stream, 250) do
             {:response, :fin, status, _headers} -> {:ok, status, ""}
             {:response, :nofin, status, _headers} ->
               case :gun.await_body(conn, stream, 250) do
                 {:ok, data} -> {:ok, status, data}
                 {:error, _} = error -> error
               end
             {:error, _} = error -> error
           end
        {:error, :timeout} -> raise "Expected gun to die, but it didn't."
        {:error, :normal} ->
          # `await_up` monitors gun and errors only if gun died (or after `timeout`). That happens
          # when gun can't connect and is out of retries (immediately in our case) so we know that
          # gun is dead.
          {:error, :noconnect}
      end
    after
      Process.unlink(conn)
      monitor = Process.monitor(conn)
      Process.exit(conn, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^conn, _}
    end
  end
end
