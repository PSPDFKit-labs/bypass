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
    :expect |> not_called
  end

  test "Bypass.expect_once raises if no request is made" do
    :expect_once |> not_called
  end

  defp not_called(expect_fun) do
    bypass = Bypass.open

    # one of Bypass.expect or Bypass.expect_once
    apply(Bypass, expect_fun, [
      bypass,
      fn _conn -> assert false end
    ])
    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :not_called, {:any, :any}} = exit_result
    end)
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

  test "Concurrent calls to down" do
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

  @tag :wip
  test "Calling a bypass route without expecting a call fails the test" do
    bypass = Bypass.open
    capture_log fn ->
      assert {:ok, 500, ""} = request(bypass.port)
    end

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_request, {:any, :any}} = exit_result
    end)
  end

  test "Bypass can handle concurrent requests with expect" do
    bypass = Bypass.open
    parent = self()

    Bypass.expect(bypass, fn conn ->
        send(parent, :request_received)
        Plug.Conn.send_resp(conn, 200, "")
      end
    )
    tasks = Enum.map(1..5, fn _ ->
      Task.async(fn -> {:ok, 200, ""} = request(bypass.port) end)
    end)
    Enum.map(tasks, fn task ->
      Task.await(task)
      assert_receive :request_received
    end)

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      :ok == Bypass.Instance.call(bypass.pid, :on_exit)
    end)
  end

  test "Bypass can handle concurrent requests with expect_once" do
    bypass = Bypass.open
    parent = self()

    Bypass.expect_once(bypass, fn conn ->
      send(parent, :request_received)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Enum.map(1..5, fn _ -> Task.async(fn -> request(bypass.port) end) end)
    |> Enum.map(fn task -> Task.await(task) end)

    assert_receive :request_received
    refute_receive :request_received

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :too_many_requests, {:any, :any}} = exit_result
    end)
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

    Enum.each(paths, fn path ->
      # one of Bypass.expect or Bypass.expect_once
      apply(Bypass, expect_fun, [
        bypass, method, path, fn conn ->
          assert conn.method == method
          assert Enum.any?(paths, fn path -> conn.request_path == path end)
          Plug.Conn.send_resp(conn, 200, "")
        end
      ])
    end)

    capture_log fn ->
      assert {:ok, 200, ""} = request(bypass.port, "/this")
    end

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :not_called, {"POST", "/that"}} = exit_result
    end)
  end

  @doc ~S"""
  Open a new HTTP connection and perform the request. We don't want to use httpc, hackney or another
  "high-level" HTTP client, since they do connection pooling and we will sometimes get a connection
  closed error and not a failed to connect error, when we test Bypass.down
  """
  def request(port, path \\ "/example_path", method \\ :post) do
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


  defp prepare_stubs do
    bypass = Bypass.open
  
    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Bypass.expect_once(bypass, "GET", "/foo", fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    bypass
  end

  test "Bypass.verify_expectations! - with ExUnit it will raise an exception" do
    bypass = Bypass.open
    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, 200, ""} = request(bypass.port)

    assert_raise RuntimeError, "Not available in ExUnit, as it's configured automatically.", fn ->
      Bypass.verify_expectations!(bypass)
    end
  end


  test "Bypass.verify_expectations! - with ESpec it will check if the expectations are being met" do
    Mix.Config.persist bypass: [test_framework: :espec]

    # Fail: no requests
    bypass = prepare_stubs()
    assert_raise ESpec.AssertionError, "No HTTP request arrived at Bypass", fn ->
      Bypass.verify_expectations!(bypass)
    end

    # Success
    bypass = prepare_stubs()
    assert {:ok, 200, ""} = request(bypass.port)
    assert {:ok, 200, ""} = request(bypass.port, "/foo", :get)
    assert :ok = Bypass.verify_expectations!(bypass)


    # Fail: no requests on a single stub
    bypass = prepare_stubs()
    assert {:ok, 200, ""} = request(bypass.port)
    assert_raise ESpec.AssertionError, "No HTTP request arrived at Bypass at GET /foo", fn ->
      Bypass.verify_expectations!(bypass)
    end

    # Fail: too many requests
    bypass = prepare_stubs()
    assert {:ok, 200, ""} = request(bypass.port)
    Task.start fn ->
      assert {:ok, 200, ""} = request(bypass.port)
    end
    assert {:ok, 200, ""} = request(bypass.port, "/foo", :get)
    :timer.sleep(10)
    assert_raise ESpec.AssertionError, "Expected only one HTTP request for Bypass", fn ->
      Bypass.verify_expectations!(bypass)
    end

    Mix.Config.persist bypass: [test_framework: :ex_unit]
  end
end
