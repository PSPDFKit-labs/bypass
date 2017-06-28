defmodule Bypass.Plug do
  def init([pid]), do: pid

  def call(%{method: method, request_path: request_path} = conn, pid) do
    route = Bypass.Instance.call(pid, {:get_route, method, request_path})
    ref = make_ref()
    case Bypass.Instance.call(pid, {:get_expect_fun, route}) do
      fun when is_function(fun, 1) ->
        retain_current_plug(pid, route, ref)
        try do
          fun.(conn)
        else
          conn ->
            put_result(pid, route, ref, :ok_call)
            conn
        catch
          class, reason ->
            stacktrace = System.stacktrace
            put_result(pid, route, ref, {:exit, {class, reason, stacktrace}})
            :erlang.raise(class, reason, stacktrace)
        end
      {:error, error, route} ->
        put_result(pid, route, ref, {:error, error, route})
        raise "Route error"
    end
  end

  defp retain_current_plug(pid, route, ref) do
    Bypass.Instance.cast(pid, {:retain_plug_process, route, ref, self()})
  end

  defp put_result(pid, route, ref, result) do
    Bypass.Instance.call(pid, {:put_expect_result, route, ref, result})
  end
end
