defmodule Bypass do
  defstruct pid: nil, port: nil

  def open do
    {:ok, pid, port} = Supervisor.start_child(Bypass.Supervisor, [])
    ExUnit.Callbacks.on_exit({Bypass, pid}, fn ->
      case Bypass.Instance.call(pid, :on_exit) do
        :ok -> :ok
        {:error, :not_called} -> raise ExUnit.AssertionError, "No HTTP request arrived at Bypass"
        {:exit, {class, reason, stacktrace}} -> :erlang.raise(class, reason, stacktrace)
      end
    end)
    %Bypass{pid: pid, port: port}
  end

  def up(%Bypass{pid: pid}), do: Bypass.Instance.call(pid, :up)

  def down(%Bypass{pid: pid}), do: Bypass.Instance.call(pid, :down)

  def expect(%Bypass{pid: pid}, fun), do: Bypass.Instance.call(pid, {:expect, fun})

  def pass(%Bypass{pid: pid}), do: Bypass.Instance.call(pid, {:put_expect_result, :ok})
end
