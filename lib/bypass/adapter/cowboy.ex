defmodule Bypass.Adapter.Cowboy do
  @moduledoc """
  `Bypass.Adapter` implementation backed by Cowboy via `Plug.Cowboy`.

  Requires the optional `:plug_cowboy` dependency. Add it to your deps and
  select this adapter with:

      config :bypass, adapter: Bypass.Adapter.Cowboy
  """

  @behaviour Bypass.Adapter

  # `:plug_cowboy` (and its `:ranch` transitive dep) is optional. Consumers who
  # do not depend on it should not get "undefined function" warnings for this
  # module, which is only reachable when they explicitly select this adapter.
  @compile {:no_warn_undefined, [Plug.Cowboy, :ranch_tcp]}

  @impl true
  def start(plug, plug_opts, port, opts) do
    Code.ensure_loaded?(Plug.Cowboy) ||
      raise """
      Bypass.Adapter.Cowboy requires the optional :plug_cowboy dependency, which \
      is not loaded. Add {:plug_cowboy, "~> 2.0"} to your deps, or use the default \
      Bypass.Adapter.Bandit adapter.
      """

    listen_ip = Keyword.fetch!(opts, :listen_ip)
    reuseport_raw = Keyword.fetch!(opts, :reuseport_raw)

    {:ok, socket} = :ranch_tcp.listen(reuseport_raw ++ [ip: listen_ip, port: port])

    cowboy_opts = [
      ref: Keyword.fetch!(opts, :ref),
      port: port,
      transport_options: [num_acceptors: Keyword.fetch!(opts, :num_acceptors), socket: socket]
    ]

    {:ok, _pid} = Plug.Cowboy.http(plug, plug_opts, cowboy_opts)
    {:ok, %{ref: cowboy_opts[:ref], socket: socket}}
  end

  @impl true
  def stop(%{ref: ref, socket: socket}) do
    :ok = Plug.Cowboy.shutdown(ref)

    # `port_close` is synchronous, so after it has returned we _know_ that the socket has been
    # closed. If we'd rely on ranch's supervisor shutting down the acceptor processes and thereby
    # killing the socket we would run into race conditions where the socket port hasn't yet gotten
    # the EXIT signal and would still be open, thereby breaking tests that rely on a closed socket.
    case :erlang.port_info(socket, :name) do
      :undefined -> :ok
      _ -> :erlang.port_close(socket)
    end

    :ok
  end
end
