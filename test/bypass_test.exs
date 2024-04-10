defmodule BypassTest do
  use ExUnit.Case
  doctest Bypass

  defdelegate capture_log(fun), to: ExUnit.CaptureLog

  test "show ISSUE #51" do
    Enum.each(
      1..1000,
      fn _ ->
        bypass = %Bypass{} = Bypass.open(port: 8000)

        Bypass.down(bypass)
      end
    )
  end

  test "Bypass.open can specify a port to operate on with expect" do
    1234 |> specify_port(:expect)
  end

  test "Bypass.open can specify a port to operate on with expect_once" do
    1235 |> specify_port(:expect_once)
  end

  defp specify_port(port, expect_fun) do
    bypass = Bypass.open(port: port)

    apply(Bypass, expect_fun, [
      bypass,
      fn conn ->
        assert port == conn.port
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    assert {:ok, 200, ""} = request(port)
    bypass2 = Bypass.open(port: port)
    assert(is_map(bypass2) and bypass2.__struct__ == Bypass)
  end

  test "Bypass.down takes down the socket with expect" do
    :expect |> down_socket
  end

  test "Bypass.down takes down the socket with expect_once" do
    :expect_once |> down_socket
  end

  defp down_socket(expect_fun) do
    bypass = Bypass.open()

    apply(Bypass, expect_fun, [
      bypass,
      fn conn -> Plug.Conn.send_resp(conn, 200, "") end
    ])

    assert {:ok, 200, ""} = request(bypass.port)

    Bypass.down(bypass)
    assert {:error, %Mint.TransportError{reason: :econnrefused}} = request(bypass.port)
  end

  test "Bypass.up opens the socket again" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, 200, ""} = request(bypass.port)

    Bypass.down(bypass)
    assert {:error, %Mint.TransportError{reason: :econnrefused}} = request(bypass.port)

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
    bypass = Bypass.open()

    apply(Bypass, expect_fun, [
      bypass,
      fn _conn -> assert false end
    ])

    # Override Bypass' on_exit handler.
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
    bypass = Bypass.open()

    apply(Bypass, expect_fun, [
      bypass,
      fn _conn ->
        Bypass.pass(bypass)
        Process.exit(self(), :shutdown)
      end
    ])

    capture_log(fn ->
      assert {:error, _conn, %Mint.TransportError{reason: :timeout}, _responses} =
               request(bypass.port)
    end)
  end

  test "closing a bypass while the request is in-flight with expect" do
    :expect |> closing_in_flight
  end

  test "closing a bypass while the request is in-flight with expect_once" do
    :expect_once |> closing_in_flight
  end

  defp closing_in_flight(expect_fun) do
    bypass = Bypass.open()

    apply(Bypass, expect_fun, [
      bypass,
      fn _conn ->
        # Mark the request as arrived, since we're shutting it down now.
        Bypass.pass(bypass)
        Bypass.down(bypass)
      end
    ])

    assert {:error, _conn, %Mint.TransportError{reason: :closed}, _responses} =
             request(bypass.port)
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
    bypass = Bypass.open()

    apply(Bypass, expect_fun, [
      bypass,
      fn conn ->
        Process.flag(:trap_exit, true)
        result = Plug.Conn.send_resp(conn, 200, "")
        Process.sleep(200)
        send(test_process, ref)
        result
      end
    ])

    assert {:ok, 200, ""} = request(bypass.port)

    # Here we make sure that Bypass.down waits until the plug process finishes
    # its work before shutting down.
    refute_received ^ref
    Bypass.down(bypass)
    assert_received ^ref
  end

  test "Concurrent calls to down" do
    test_process = self()
    ref = make_ref()
    bypass = Bypass.open()

    Bypass.expect(
      bypass,
      "POST",
      "/this",
      fn conn ->
        Process.sleep(100)
        Plug.Conn.send_resp(conn, 200, "")
      end
    )

    Bypass.expect(
      bypass,
      "POST",
      "/that",
      fn conn ->
        Process.sleep(100)
        result = Plug.Conn.send_resp(conn, 200, "")
        send(test_process, ref)
        result
      end
    )

    assert {:ok, 200, ""} = request(bypass.port, "/this")

    tasks =
      Enum.map(1..5, fn _ ->
        Task.async(fn ->
          assert {:ok, 200, ""} = request(bypass.port, "/that")
          Bypass.down(bypass)
        end)
      end)

    # Here we make sure that Bypass.down waits until the plug process finishes
    # its work before shutting down.
    refute_received ^ref
    Process.sleep(200)
    Bypass.down(bypass)

    Enum.map(tasks, fn task ->
      Task.await(task)
      assert_received ^ref
    end)
  end

  @tag :wip
  test "Calling a bypass route without expecting a call fails the test" do
    bypass = Bypass.open()

    capture_log(fn ->
      assert {:ok, 500, ""} = request(bypass.port)
    end)

    # Override Bypass' on_exit handler.
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :unexpected_request, {:any, :any}} = exit_result
    end)
  end

  test "Bypass can handle concurrent requests with expect" do
    bypass = Bypass.open()
    parent = self()

    Bypass.expect(bypass, fn conn ->
      send(parent, :request_received)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    tasks =
      Enum.map(1..5, fn _ ->
        Task.async(fn -> {:ok, 200, ""} = request(bypass.port) end)
      end)

    Enum.map(tasks, fn task ->
      Task.await(task)
      assert_receive :request_received
    end)

    # Override Bypass' on_exit handler.
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      :ok == Bypass.Instance.call(bypass.pid, :on_exit)
    end)
  end

  test "Bypass can handle concurrent requests with expect_once" do
    bypass = Bypass.open()
    parent = self()

    Bypass.expect_once(bypass, fn conn ->
      send(parent, :request_received)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Enum.map(1..5, fn _ -> Task.async(fn -> request(bypass.port) end) end)
    |> Enum.map(fn task -> Task.await(task) end)

    assert_receive :request_received
    refute_receive :request_received

    # Override Bypass' on_exit handler.
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :too_many_requests, {:any, :any}} = exit_result
    end)
  end

  test "Bypass.stub/4 does not raise if request is made" do
    :stub |> specific_route
  end

  test "Bypass.stub/4 does not raise if request is not made" do
    :stub |> set_expectation("/stub_path")
  end

  test "Bypass.expect/4 can be used to define a specific route" do
    :expect |> specific_route
  end

  test "Bypass.expect_once/4 can be used to define a specific route" do
    :expect_once |> specific_route
  end

  defp set_expectation(action, path) do
    bypass = Bypass.open()
    method = "POST"

    apply(Bypass, action, [
      bypass,
      method,
      path,
      fn conn ->
        assert conn.method == method
        assert conn.request_path == path
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])
  end

  defp specific_route(expect_fun) do
    bypass = Bypass.open()
    method = "POST"
    path = "/this"

    apply(Bypass, expect_fun, [
      bypass,
      method,
      path,
      fn conn ->
        assert conn.method == method
        assert conn.request_path == path
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log(fn ->
      assert {:ok, 200, ""} = request(bypass.port, path)
    end)
  end

  test "Bypass.stub/4 does not raise if request with parameters is made" do
    :stub |> specific_route_with_params
  end

  test "Bypass.expect/4 can be used to define a specific route with parameters" do
    :expect |> specific_route_with_params
  end

  test "Bypass.expect_once/4 can be used to define a specific route with parameters" do
    :expect_once |> specific_route_with_params
  end

  defp specific_route_with_params(expect_fun) do
    bypass = Bypass.open()
    method = "POST"
    pattern = "/this/:resource/get/:id"
    path = "/this/my_resource/get/1234"

    apply(Bypass, expect_fun, [
      bypass,
      method,
      pattern,
      fn conn ->
        assert conn.method == method
        assert conn.request_path == path

        assert conn.params == %{
                 "resource" => "my_resource",
                 "id" => "1234",
                 "q_param_1" => "a",
                 "q_param_2" => "b"
               }

        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log(fn ->
      assert {:ok, 200, ""} = request(bypass.port, path <> "?q_param_1=a&q_param_2=b")
    end)
  end

  test "All routes to a Bypass.expect/4 call must be called" do
    :expect |> all_routes_must_be_called
  end

  test "All routes to a Bypass.expect_once/4 call must be called" do
    :expect_once |> all_routes_must_be_called
  end

  defp all_routes_must_be_called(expect_fun) do
    bypass = Bypass.open()
    method = "POST"
    paths = ["/this", "/that"]

    Enum.each(paths, fn path ->
      apply(Bypass, expect_fun, [
        bypass,
        method,
        path,
        fn conn ->
          assert conn.method == method
          assert Enum.any?(paths, fn path -> conn.request_path == path end)
          Plug.Conn.send_resp(conn, 200, "")
        end
      ])
    end)

    capture_log(fn ->
      assert {:ok, 200, ""} = request(bypass.port, "/this")
    end)

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      exit_result = Bypass.Instance.call(bypass.pid, :on_exit)
      assert {:error, :not_called, {"POST", "/that"}} = exit_result
    end)
  end

  @doc ~S"""
  Open a new HTTP connection and perform the request. We don't want to use httpc, hackney or another
  "high-level" HTTP client, since they do connection pooling and we will sometimes get a connection
  closed error and not a failed to connect error, when we test Bypass.down.
  """
  def request(port, path \\ "/example_path", method \\ "POST") do
    with {:ok, conn} <- Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, method, path, [], "") do
      receive_responses(conn, ref, 100, [])
    end
  end

  defp receive_responses(conn, ref, status, body) do
    with {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, 200) do
      receive_responses(responses, conn, ref, status, body)
    end
  end

  defp receive_responses([], conn, ref, status, body) do
    receive_responses(conn, ref, status, body)
  end

  defp receive_responses([response | responses], conn, ref, status, body) do
    case response do
      {:status, ^ref, status} ->
        receive_responses(responses, conn, ref, status, body)

      {:headers, ^ref, _headers} ->
        receive_responses(responses, conn, ref, status, body)

      {:data, ^ref, data} ->
        receive_responses(responses, conn, ref, status, [data | body])

      {:done, ^ref} ->
        _ = Mint.HTTP.close(conn)
        {:ok, status, body |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, ^ref, _reason} = error ->
        error
    end
  end

  test "Bypass.expect/4 can be used to define a specific route and then redefine it later" do
    :expect |> specific_route_redefined
  end

  test "Bypass.expect_once/4 can be used to define a specific route and then redefine it later" do
    :expect_once |> specific_route_redefined
  end

  defp specific_route_redefined(expect_fun) do
    bypass = Bypass.open()
    method = "POST"
    path = "/this"

    apply(Bypass, expect_fun, [
      bypass,
      method,
      path,
      fn conn ->
        assert conn.method == method
        assert conn.request_path == path
        Plug.Conn.send_resp(conn, 200, "")
      end
    ])

    capture_log(fn ->
      assert {:ok, 200, ""} = request(bypass.port, path)
    end)

    # Redefine the expect
    apply(Bypass, expect_fun, [
      bypass,
      method,
      path,
      fn conn ->
        assert conn.method == method
        assert conn.request_path == path
        Plug.Conn.send_resp(conn, 200, "other response")
      end
    ])

    capture_log(fn ->
      assert {:ok, 200, "other response"} = request(bypass.port, path)
    end)
  end

  defp prepare_stubs do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Bypass.expect_once(bypass, "GET", "/foo", fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    bypass
  end

  test "Bypass.verify_expectations! - with ExUnit it will raise an exception" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, 200, ""} = request(bypass.port)

    assert_raise RuntimeError, "Not available in ExUnit, as it's configured automatically.", fn ->
      Bypass.verify_expectations!(bypass)
    end
  end

  test "Bypass.verify_expectations! - with ESpec it will check if the expectations are being met" do
    Application.put_all_env(bypass: [test_framework: :espec])

    # Fail: no requests
    bypass = prepare_stubs()

    assert_raise ESpec.AssertionError, "No HTTP request arrived at Bypass", fn ->
      Bypass.verify_expectations!(bypass)
    end

    # Success
    bypass = prepare_stubs()
    assert {:ok, 200, ""} = request(bypass.port)
    assert {:ok, 200, ""} = request(bypass.port, "/foo", "GET")
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

    Task.start(fn ->
      assert {:ok, 200, ""} = request(bypass.port)
    end)

    assert {:ok, 200, ""} = request(bypass.port, "/foo", "GET")
    :timer.sleep(10)

    assert_raise ESpec.AssertionError, "Expected only one HTTP request for Bypass", fn ->
      Bypass.verify_expectations!(bypass)
    end

    Application.put_all_env(bypass: [test_framework: :ex_unit])
  end

  test "Bypass.open/1 raises when cannot start child" do
    assert_raise RuntimeError, ~r/Failed to start bypass instance/, fn ->
      Bypass.open(:error)
    end
  end
end
