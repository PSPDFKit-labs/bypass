defmodule Bypass do
  defstruct pid: nil, port: nil

  import Bypass.Utils
  require Logger

  def open(opts \\ []) do
    case Supervisor.start_child(Bypass.Supervisor, [opts]) do
      {:ok, pid} ->
        port = Bypass.Instance.call(pid, :port)
        debug_log "Did open connection #{inspect pid} on port #{inspect port}"
        ExUnit.Callbacks.on_exit({Bypass, pid}, fn ->
          case Bypass.Instance.call(pid, :on_exit) do
            :ok ->
              :ok
            :ok_call ->
              :ok
            {:error, :unexpected_count, errors} ->
              raise ExUnit.AssertionError, errors
            {:error, :disallowed_expect} ->
              raise ExUnit.AssertionError, "Passed expect function is not a function"
            {:exit, {class, reason, stacktrace}} ->
              :erlang.raise(class, reason, stacktrace)
          end
        end)
        %Bypass{pid: pid, port: port}
      other ->
        other
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
