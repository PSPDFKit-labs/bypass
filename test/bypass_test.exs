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
    bypass = Bypass.open
    parent = self()
    Bypass.expect(bypass, fn conn ->
      send(parent, :request_received)
      Plug.Conn.send_resp(conn, 200, "")
    end)
    Enum.each(1..5, fn _ ->
      assert {:ok, 200, ""} = request(bypass.port)
      assert_receive :request_received
    end)
  end

  test "Bypass.open can specify a port to operate on" do
    port = 1234
    bypass = Bypass.open(port: port)

    Bypass.expect(bypass, fn conn ->
      assert port == conn.port
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, 200, ""} = request(port)

    assert {:error, :eaddrinuse} == Bypass.open(port: port)
  end

  test "Bypass.down takes down the socket" do
    bypass = Bypass.open
    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)
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
    bypass = Bypass.open
    Bypass.expect(bypass, fn _conn ->
      assert false
    end)
    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      assert {:error, :not_called} == Bypass.Instance.call(bypass.pid, :on_exit)
    end)
  end

  test "Bypass.expect can be canceled by expecting nil" do
    bypass = Bypass.open
    Bypass.expect(bypass, fn _conn ->
      assert false
    end)
    Bypass.expect(bypass, nil)
  end

  test "Bypass.expect can be made to pass by calling Bypass.pass" do
    bypass = Bypass.open
    Bypass.expect(bypass, fn _conn ->
      Bypass.pass(bypass)
      Process.exit(self(), :normal)
      assert false
    end)

    capture_log fn ->
      assert {:error, {:closed, 'The connection was lost.'}} = request(bypass.port)
    end
  end

  test "Calling a bypass without expecting a call fails the test" do
    bypass = Bypass.open
    capture_log fn ->
      assert {:ok, 500, ""} = request(bypass.port)
    end

    # Override Bypass' on_exit handler
    ExUnit.Callbacks.on_exit({Bypass, bypass.pid}, fn ->
      assert {:error, :unexpected_request} == Bypass.Instance.call(bypass.pid, :on_exit)
    end)
  end

  test "closing a bypass while the request is in-flight" do
    bypass = Bypass.open
    Bypass.expect(bypass, fn _conn ->
      Bypass.pass(bypass) # mark the request as arrived, since we're shutting it down now
      Bypass.down(bypass)
    end)
    assert {:error, {:closed, 'The connection was lost.'}} == request(bypass.port)
  end

  test "Bypass.down waits for plug process to terminate before shutting it down" do
    test_process = self()
    ref = make_ref()

    bypass = Bypass.open
    Bypass.expect(bypass, fn conn ->
      result = Plug.Conn.send_resp(conn, 200, "")
      :timer.sleep(200)
      send(test_process, ref)
      result
    end)

    assert {:ok, 200, ""} = request(bypass.port)

    # Here we make sure that Bypass.down waits until the plug process finishes its work
    # before shutting down
    refute_received ^ref
    Bypass.down(bypass)
    assert_received ^ref
  end

  test "on_exit handler when the request hasn't finished" do
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      result = Plug.Conn.send_resp(conn, 200, "")
      :timer.sleep(200)
      result
    end
    assert {:ok, 200, ""} = request(bypass.port)
    # on_exit should wait for the response, rather that saying the request
    # wasn't made.
  end

  @doc ~S"""
  Open a new HTTP connection and perform the request. We don't want to use httpc, hackney or another
  "high-level" HTTP client, since they do connection pooling and we will sometimes get a connection
  closed error and not a failed to connect error, when we test Bypass.down
  """
  def request(port, path \\ "") do
    {:ok, conn} = :gun.start_link(self(), '127.0.0.1', port, %{retry: 0})
    try do
      case :gun.await_up(conn, 250) do
        {:ok, _protocol} ->
           stream = :gun.post(conn, path, [], "")
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
