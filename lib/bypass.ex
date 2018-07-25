defmodule Bypass do
  @moduledoc """
  Bypass provides a quick way to create a custom Plug that can be put
  in place instead of an actual HTTP server to return prebaked responses
  to client requests.

  This module is the main interface to the library.
  """

  defstruct pid: nil, port: nil

  import Bypass.Utils
  require Logger

  @doc """
  Starts an Elixir process running a minimal Plug app. The process
  is a HTTP handler and listens to requests on a TCP port on localhost.

  Use the other functions in this module to declare which requests are
  handled and set expectations on the calls.
  """
  def open(opts \\ []) do
    case Supervisor.start_child(Bypass.Supervisor, [opts]) do
      {:ok, pid} ->
        port = Bypass.Instance.call(pid, :port)
        debug_log "Did open connection #{inspect pid} on port #{inspect port}"
        bypass = %Bypass{pid: pid, port: port}
        setup_framework_integration(test_framework(), bypass)
        bypass
      other ->
        other
    end
  end


  # Raise an error if called with an unknown framework
  #
  defp setup_framework_integration(:ex_unit, bypass = %{pid: pid}) do
    ExUnit.Callbacks.on_exit({Bypass, pid}, fn ->
      do_verify_expectations(bypass.pid, ExUnit.AssertionError)
    end)
  end

  defp setup_framework_integration(:espec, _bypass) do
    # Entry point for more advanced ESpec configurations
  end


  @doc """
  Can be called to immediately verify if the declared request
  expectations have been met.

  Returns `:ok` on success and raises an error on failure.
  """
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


  def up(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :up)

  def down(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :down)

  def expect(%Bypass{pid: pid}, fun),
    do: Bypass.Instance.call(pid, {:expect, fun})

  def expect(%Bypass{pid: pid}, methods, paths, fun),
    do: Bypass.Instance.call(pid, {:expect, methods, paths, fun})

  def expect_once(%Bypass{pid: pid}, fun),
    do: Bypass.Instance.call(pid, {:expect_once, fun})

  def expect_once(%Bypass{pid: pid}, methods, paths, fun),
    do: Bypass.Instance.call(pid, {:expect_once, methods, paths, fun})

  def stub(%Bypass{pid: pid}, methods, paths, fun),
    do: Bypass.Instance.call(pid, {:stub, methods, paths, fun})

  def pass(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :pass)


  defp test_framework do
    Application.get_env(:bypass, :test_framework, :ex_unit)
  end
end
