defmodule Bypass do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  defstruct pid: nil, port: nil

  @typedoc """
  Represents a Bypass server process.
  """
  @type t :: %__MODULE__{pid: pid, port: non_neg_integer}

  import Bypass.Utils
  require Logger

  @doc """
  Starts an Elixir process running a minimal Plug app. The process is a HTTP
  handler and listens to requests on a TCP port on localhost.

  Use the other functions in this module to declare which requests are handled
  and set expectations on the calls.

  ## Options

  - `port` - Optional TCP port to listen to requests.

  ## Examples

  ```elixir
  bypass = Bypass.open()
  ```

  Assign a specific port to a Bypass instance to listen on:

  ```elixir
  bypass = Bypass.open(port: 1234)
  ```

  """
  @spec open(Keyword.t()) :: Bypass.t()
  def open(opts \\ []) do
    pid = start_instance(opts)
    port = Bypass.Instance.call(pid, :port)
    debug_log("Did open connection #{inspect(pid)} on port #{inspect(port)}")
    bypass = %Bypass{pid: pid, port: port}
    setup_framework_integration(test_framework(), bypass)
    bypass
  end

  defp start_instance(opts) do
    case DynamicSupervisor.start_child(Bypass.Supervisor, Bypass.Instance.child_spec(opts)) do
      {:ok, pid} ->
        pid

      {:ok, pid, _info} ->
        pid

      {:error, reason} ->
        raise "Failed to start bypass instance.\n" <>
                "Reason: #{start_supervised_error(reason)}"
    end
  end

  defp start_supervised_error({{:EXIT, reason}, info}) when is_tuple(info),
    do: Exception.format_exit(reason)

  defp start_supervised_error({reason, info}) when is_tuple(info),
    do: Exception.format_exit(reason)

  defp start_supervised_error(reason), do: Exception.format_exit({:start_spec, reason})

  defp setup_framework_integration(:ex_unit, bypass = %{pid: pid}) do
    ExUnit.Callbacks.on_exit({Bypass, pid}, fn ->
      do_verify_expectations(bypass.pid, ExUnit.AssertionError)
    end)
  end

  defp setup_framework_integration(:espec, _bypass) do
  end

  @doc """
  Can be called to immediately verify if the declared request expectations have
  been met.

  Returns `:ok` on success and raises an error on failure.
  """
  @spec verify_expectations!(Bypass.t()) :: :ok | no_return()
  def verify_expectations!(bypass) do
    verify_expectations!(test_framework(), bypass)
  end

  defp verify_expectations!(:ex_unit, _bypass) do
    raise "Not available in ExUnit, as it's configured automatically."
  end

  if Code.ensure_loaded?(ESpec) do
    defp verify_expectations!(:espec, bypass) do
      do_verify_expectations(bypass.pid, ESpec.AssertionError)
    end
  end

  defp do_verify_expectations(bypass_pid, error_module) do
    case Bypass.Instance.call(bypass_pid, :on_exit) do
      :ok ->
        :ok

      :ok_call ->
        :ok

      {:error, :too_many_requests, {:any, :any}} ->
        raise error_module, "Expected only one HTTP request for Bypass"

      {:error, :too_many_requests, {method, path}} ->
        raise error_module, "Expected only one HTTP request for Bypass at #{method} #{path}"

      {:error, :unexpected_request, {:any, :any}} ->
        raise error_module, "Bypass got an HTTP request but wasn't expecting one"

      {:error, :unexpected_request, {method, path}} ->
        raise error_module,
              "Bypass got an HTTP request but wasn't expecting one at #{method} #{path}"

      {:error, :not_called, {:any, :any}} ->
        raise error_module, "No HTTP request arrived at Bypass"

      {:error, :not_called, {method, path}} ->
        raise error_module,
              "No HTTP request arrived at Bypass at #{method} #{path}"

      {:exit, {class, reason, stacktrace}} ->
        :erlang.raise(class, reason, stacktrace)
    end
  end

  @doc """
  Re-opens the TCP socket on the same port. Blocks until the operation is
  complete.

  ```elixir
  Bypass.up(bypass)
  ```
  """
  @spec up(Bypass.t()) :: :ok | {:error, :already_up}
  def up(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :up)

  @doc """
  Closes the TCP socket. Blocks until the operation is complete.

  ```elixir
  Bypass.down(bypass)
  ```
  """
  @spec down(Bypass.t()) :: :ok | {:error, :already_down}
  def down(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :down)

  @doc """
  Expects the passed function to be called at least once regardless of the route.

  ```elixir
  Bypass.expect(bypass, fn conn ->
    assert "/1.1/statuses/update.json" == conn.request_path
    assert "POST" == conn.method
    Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
  end)
  ```
  """
  @spec expect(Bypass.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect(%Bypass{pid: pid}, fun),
    do: Bypass.Instance.call(pid, {:expect, fun})

  @doc """
  Expects the passed function to be called at least once for the specified route (method and path).

  - `method` is one of `["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT"]`

  - `path` is the endpoint.

  ```elixir
  Bypass.expect(bypass, "POST", "/1.1/statuses/update.json", fn conn ->
    Agent.get_and_update(AgentModule, fn step_no -> {step_no, step_no + 1} end)
    Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
  end)
  ```
  """
  @spec expect(Bypass.t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect(%Bypass{pid: pid}, method, path, fun),
    do: Bypass.Instance.call(pid, {:expect, method, path, fun})

  @doc """
  Expects the passed function to be called exactly once regardless of the route.

  ```elixir
  Bypass.expect_once(bypass, fn conn ->
    assert "/1.1/statuses/update.json" == conn.request_path
    assert "POST" == conn.method
    Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
  end)
  ```
  """
  @spec expect_once(Bypass.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_once(%Bypass{pid: pid}, fun),
    do: Bypass.Instance.call(pid, {:expect_once, fun})

  @doc """
  Expects the passed function to be called exactly once for the specified route (method and path).

  - `method` is one of `["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT"]`

  - `path` is the endpoint.

  ```elixir
  Bypass.expect_once(bypass, "POST", "/1.1/statuses/update.json", fn conn ->
    Agent.get_and_update(AgentModule, fn step_no -> {step_no, step_no + 1} end)
    Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
  end)
  ```
  """
  @spec expect_once(Bypass.t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_once(%Bypass{pid: pid}, method, path, fun),
    do: Bypass.Instance.call(pid, {:expect_once, method, path, fun})

  @doc """
  Allows the function to be invoked zero or many times for the specified route (method and path).

  - `method` is one of `["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT"]`

  - `path` is the endpoint.

  ```elixir
  Bypass.stub(bypass, "POST", "/1.1/statuses/update.json", fn conn ->
    Agent.get_and_update(AgentModule, fn step_no -> {step_no, step_no + 1} end)
    Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
  end)
  ```
  """
  @spec stub(Bypass.t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub(%Bypass{pid: pid}, method, path, fun),
    do: Bypass.Instance.call(pid, {:stub, method, path, fun})

  @doc """
  Makes an expectation to pass.

  ```
  Bypass.expect(bypass, fn _conn ->
    Bypass.pass(bypass)

    assert false
  end)
  """
  @spec pass(Bypass.t()) :: :ok
  def pass(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :pass)

  defp test_framework do
    Application.get_env(:bypass, :test_framework, :ex_unit)
  end
end
