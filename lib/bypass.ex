defmodule Bypass do
  defstruct pid: nil, port: nil, ref: nil

  def start_link(ref) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Agent, [fn -> %{ref: ref, fun: nil, result: nil} end, [name: Bypass.State.name(ref)]])
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, max_restarts: 0)
  end

  def open do
    import Supervisor.Spec, warn: false
    ref = make_ref()
    child = supervisor(Bypass, [ref], id: ref, max_restarts: 0)
    {:ok, pid} = Supervisor.start_child(Bypass.Supervisor, child)
    do_up(ref, 0)
    port = :ranch.get_port(ref)
    bypass = %Bypass{pid: pid, port: port, ref: ref}
    ExUnit.Callbacks.on_exit({Bypass, :open, ref}, fn -> Bypass.close(bypass) end)
    bypass
  end

  def close(%Bypass{ref: ref} = bypass) do
    case Supervisor.terminate_child(Bypass.Supervisor, ref) do
      :ok ->
        :ok = Supervisor.delete_child(Bypass.Supervisor, ref)
        :ranch_server.cleanup_listener_opts(ref)
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

  defp do_up(ref, port),
    do: {:ok, _} = Supervisor.start_child(sup(ref), Bypass.Plug.child_spec(ref, port))

end
