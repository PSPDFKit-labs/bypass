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
      # Bypass is a test server; suppress Bandit's per-start "Running ... at ..."
      # info log so it doesn't spam consumers' test output on every open/up.
      startup_log: false,
      thousand_island_options: [
        num_acceptors: Keyword.fetch!(opts, :num_acceptors),
        # Drop in-flight connections immediately on shutdown instead of draining
        # them. Bypass already waits (via callers_awaiting_down) for retained plug
        # processes to finish before stopping, so by the time we tear the server
        # down there is nothing to drain — and draining would deadlock a plug that
        # calls Bypass.down/1 on itself while still in-flight.
        shutdown_timeout: 0,
        # Thousand Island opens its own listen socket, so (unlike the Cowboy
        # adapter) we can't hand it a pre-opened one. `reuseaddr` (a Thousand
        # Island default, set explicitly) plus SO_REUSEPORT let us re-listen on
        # the same port across down/up cycles without hitting :eaddrinuse.
        # Thousand Island rejects the raw setsockopt tuple the Cowboy adapter
        # uses, so we use the `reuseport` inet option (OTP 25+) instead — only on
        # platforms where it is supported, mirroring Bypass.Utils.so_reuseport/0.
        transport_options: [ip: listen_ip, reuseaddr: true] ++ reuseport_opt()
      ]
    )
  end

  @impl true
  def stop(pid) when is_pid(pid) do
    # Stopping the Bandit supervisor terminates the Thousand Island listener,
    # which closes the listen socket as it exits. Thousand Island does not close
    # the socket in its `terminate/2`, so — like the Cowboy adapter's explicit
    # `port_close` — callers relying on an immediate :econnrefused after
    # `Bypass.down/1` depend on this teardown completing before we return, which
    # the synchronous `Supervisor.stop/3` guarantees.
    :ok = Supervisor.stop(pid, :normal, :infinity)
  end

  defp reuseport_opt do
    case :os.type() do
      {:unix, os} when os in [:linux, :darwin] -> [reuseport: true]
      _ -> []
    end
  end
end
