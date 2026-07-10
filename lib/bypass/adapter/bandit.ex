defmodule Bypass.Adapter.Bandit do
  @moduledoc """
  `Bypass.Adapter` implementation backed by [Bandit](https://hex.pm/packages/bandit).

  This is the default adapter. It requires no extra configuration; to switch
  back to Cowboy see `Bypass.Adapter.Cowboy`.
  """

  @behaviour Bypass.Adapter

  @impl true
  def start(plug, plug_opts, port, opts) do
    listen_ip = Keyword.fetch!(opts, :listen_ip)

    Bandit.start_link(
      plug: {plug, plug_opts},
      scheme: :http,
      port: port,
      thousand_island_options: [
        num_acceptors: Keyword.fetch!(opts, :num_acceptors),
        # Drop in-flight connections immediately on shutdown instead of draining
        # them. Bypass already waits (via callers_awaiting_down) for retained plug
        # processes to finish before stopping, so by the time we tear the server
        # down there is nothing to drain — and draining would deadlock a plug that
        # calls Bypass.down/1 on itself while still in-flight.
        shutdown_timeout: 0,
        # Thousand Island opens its own listen socket, so (unlike the Cowboy
        # adapter) we can't hand it a pre-opened one. Instead we ask the kernel
        # for SO_REUSEPORT via the `reuseport` inet option so we can re-listen on
        # the same port across down/up cycles without hitting :eaddrinuse.
        # `reuseport` requires OTP 25+; Thousand Island rejects the raw setsockopt
        # tuple form the Cowboy adapter uses, so this is the only option here.
        transport_options: [ip: listen_ip, reuseport: true]
      ]
    )
  end

  @impl true
  def stop(pid) when is_pid(pid) do
    :ok = Supervisor.stop(pid, :normal, :infinity)
  end
end
