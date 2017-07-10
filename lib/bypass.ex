defmodule Bypass do
  defstruct pid: nil, port: nil

  import Bypass.Utils
  require Logger


  def open(opts \\ []) do
    open(:ex_unit, opts)
  end

  def open(framework, opts) do
    case Supervisor.start_child(Bypass.Supervisor, [opts]) do
      {:ok, pid} ->
        port = Bypass.Instance.call(pid, :port)
        debug_log "Did open connection #{inspect pid} on port #{inspect port}"
        setup_expectations_verifications(framework, pid)
        %Bypass{pid: pid, port: port}
      other ->
        other
    end
  end

  defp setup_expectations_verifications(:ex_unit, pid) do
    ExUnit.Callbacks.on_exit({Bypass, pid}, fn ->
      do_verify_expectations(pid, ExUnit.AssertionError)
    end)
  end

  defp setup_expectations_verifications(_framework, _pid), do: nil


  if Code.ensure_loaded?(ESpec) do
    def verify_expectations(:espec, bypass) do
      do_verify_expectations(bypass.pid, ESpec.AssertionError)
    end    
  end

  def verify_expectations(_framework, _bypass), do: nil


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

  def pass(%Bypass{pid: pid}),
    do: Bypass.Instance.call(pid, :pass)

end
