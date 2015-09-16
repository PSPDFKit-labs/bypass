defmodule Bypass do
  defstruct pid: nil, port: nil, ref: nil

  def start_link(ref) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Agent, [fn -> %{ref: ref, fun: nil, result: nil} end, [name: Bypass.State.name(ref)]]),
      Bypass.Plug.child_spec(ref)
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, max_restarts: 0)
  end

  def open do
    import Supervisor.Spec, warn: false
    ref = make_ref()
    child = supervisor(Bypass, [ref], id: ref, max_restarts: 0)
    {:ok, pid} = Supervisor.start_child(Bypass.Supervisor, child)
    port = :ranch.get_port(ref)
    bypass = %Bypass{pid: pid, port: port, ref: ref}
    ExUnit.Callbacks.on_exit({Bypass, :open, ref}, fn -> Bypass.stop(bypass) end)
    bypass
  end

  def stop(%Bypass{ref: ref} = _bypass) do
    case Supervisor.terminate_child(Bypass.Supervisor, ref) do
      :ok ->
        :ok = Supervisor.delete_child(Bypass.Supervisor, ref)
      {:error, :not_found} = error ->
        error
    end
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
end
