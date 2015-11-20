defmodule Bypass.Plug do
  def init([pid]), do: pid

  def call(conn, pid) do
    case Bypass.Instance.call(pid, :get_expect_fun) do
      fun when is_function(fun, 1) ->
        retain_current_plug(pid)
        try do
          fun.(conn)
        else
          conn ->
            put_result(pid, :ok_call)
            conn
        catch
          class, reason ->
            stacktrace = System.stacktrace
            put_result(pid, {:exit, {class, reason, stacktrace}})
            :erlang.raise(class, reason, stacktrace)
        end
      nil ->
        put_result(pid, {:error, :unexpected_request})
        conn
    end
  end

  defp retain_current_plug(pid), do: Bypass.Instance.cast(pid, {:retain_plug_process, self()})
  defp put_result(pid, result), do: Bypass.Instance.call(pid, {:put_expect_result, result})
end
