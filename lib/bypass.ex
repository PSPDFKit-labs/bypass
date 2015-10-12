defmodule Bypass do
  defstruct pid: nil, port: nil, ref: nil

  def start_link(ref) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Agent, [fn -> %{ref: ref, fun: nil, result: nil, socket: nil} end, [name: Bypass.State.name(ref)]])
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, max_restarts: 0)
  end

  def open do
    import Supervisor.Spec, warn: false
    ref = make_ref()

    # just get a free port
    {:ok, socket} = :ranch_tcp.listen(port: 0)
    {:ok, port} = :inet.port(socket)
    :erlang.port_close(socket)

    child = supervisor(Bypass, [ref], id: ref, max_restarts: 0)
    {:ok, pid} = Supervisor.start_child(Bypass.Supervisor, child)

    do_up(ref, port)
    bypass = %Bypass{pid: pid, port: port, ref: ref}
    ExUnit.Callbacks.on_exit({Bypass, :open, ref}, fn -> Bypass.close(bypass) end)
    bypass
  end

  def close(%Bypass{ref: ref} = _bypass) do
    socket = Bypass.State.get_socket(ref)
    case Supervisor.terminate_child(Bypass.Supervisor, ref) do
      :ok ->
        :ok = Supervisor.delete_child(Bypass.Supervisor, ref)
        :ranch_server.cleanup_listener_opts(ref)
        close_socket(socket)
      {:error, :not_found} = error ->
        error
    end
  end

  def up(%Bypass{ref: ref, port: port}) do
    do_up(ref, port)
  end

  def down(%Bypass{ref: ref} = _bypass) do
    :ok = Supervisor.terminate_child(sup(ref), {:ranch_listener_sup, ref})
    :ok = Supervisor.delete_child(sup(ref), {:ranch_listener_sup, ref})
    :ranch_server.cleanup_listener_opts(ref)
    close_socket(Bypass.State.get_socket(ref))
  end

  def expect(%Bypass{ref: ref} = _bypass, fun) do
    Bypass.State.put_fun(ref, fun)
    ExUnit.Callbacks.on_exit {Bypass, :expect, ref}, fn ->
      case Bypass.State.get_result(ref) do
        :ok -> :ok
        nil -> raise ExUnit.AssertionError, "No HTTP request arrived at Bypass"
        {class, reason, stacktrace} -> :erlang.raise(class, reason, stacktrace)
      end
    end
  end

  def cancel_expect(%Bypass{ref: ref} = _bypass) do
    Bypass.State.put_fun(ref, nil)
    ExUnit.Callbacks.on_exit {Bypass, :expect, ref}, fn -> :ok end
  end

  defp sup(ref) do
    {^ref, supervisor, _, _} = Supervisor.which_children(Bypass.Supervisor) |> List.keyfind(ref, 0)
    supervisor
  end

  defp do_up(ref, port) do
    socket = Bypass.State.make_socket(ref, port)
    ExUnit.Callbacks.on_exit({Bypass, :close_socket, ref}, fn -> close_socket(socket) end)
    {:ok, _} = Supervisor.start_child(sup(ref), Bypass.Plug.child_spec(ref, port, socket))
  end

  # Close socket if it's open.
  defp close_socket(socket) do
    case :erlang.port_info(socket, :name) do
      :undefined -> :ok
      _ -> :erlang.port_close(socket)
    end
  end
end
