defmodule Bypass.State do
  def name(ref), do:  {:global, {Bypass, ref}}

  def get_fun(ref) do
    Agent.get(name(ref), fn s -> s.fun end)
  end

  def get_result(ref) do
    Agent.get(name(ref), fn s -> s.result end)
  end

  def put_result(ref, result) do
    Agent.update(name(ref), fn s -> %{s | result: result} end)
  end

  def put_fun(ref, fun) do
    Agent.update(name(ref), fn s -> %{s | fun: fun} end)
  end

  def make_socket(ref, port) do
    Agent.get_and_update(name(ref), fn s ->
      {:ok, socket} = :ranch_tcp.listen(port: port)
      {socket, %{s | socket: socket}}
    end)
  end

  def get_socket(ref) do
    Agent.get(name(ref), fn s -> s.socket end)
  end
end
