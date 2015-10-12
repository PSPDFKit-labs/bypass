defmodule Bypass.Plug do
  import Plug.Conn

  @doc "Child spec for the supervisor."
  def child_spec(ref, port, socket) do
    Plug.Adapters.Cowboy.child_spec(:http, __MODULE__, [ref], [ref: ref, acceptors: 5, port: port, socket: socket])
  end

  def init([ref]), do: ref

  def call(conn, ref) do
    try do
      Bypass.State.get_fun(ref).(conn)
    else
      conn ->
        Bypass.State.put_result(ref, :ok)
        conn
    catch
      class, reason ->
        stacktrace = System.stacktrace
        Bypass.State.put_result(ref, {class, reason, stacktrace})
        :erlang.raise(class, reason, stacktrace)
    end
  end
end
