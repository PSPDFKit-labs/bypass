defmodule Bypass.Adapter.Cowboy do
  @moduledoc """
  `Bypass.Adapter` implementation backed by Cowboy via `Plug.Cowboy`.

  Requires the optional `:plug_cowboy` dependency:

      # mix.exs
      {:plug_cowboy, "~> 2.0", only: :test}

      # config/test.exs
      config :bypass, adapter: Bypass.Adapter.Cowboy

  This adapter pre-opens the listen socket (to apply `SO_REUSEPORT`) and hands it
  to Cowboy, which only ranch 1.x supports — ranch 2.x removed the pre-opened
  socket option. Bypass depends on `ranch ~> 1.8`, which constrains resolution
  for you, so no explicit ranch pin is normally needed.
  """

  @behaviour Bypass.Adapter

  # `:plug_cowboy` is optional. Consumers who do not depend on it should not get
  # "undefined function" warnings for this module, which is only reachable when
  # they explicitly select this adapter.
  @compile {:no_warn_undefined, [Plug.Cowboy]}

  # Socket options mirroring ranch_tcp's defaults, so the pre-opened socket we
  # hand to Cowboy behaves the same as one Cowboy/ranch would open itself.
  @socket_opts [:binary, active: false, reuseaddr: true, nodelay: true, backlog: 1_024]

  @impl true
  def start(plug, plug_opts, port, opts) do
    Code.ensure_loaded?(Plug.Cowboy) ||
      raise """
      Bypass.Adapter.Cowboy requires the optional :plug_cowboy dependency, which \
      is not loaded. Add {:plug_cowboy, "~> 2.0"} to your deps, or use the default \
      Bypass.Adapter.Bandit adapter.
      """

    ranch_1_x?() ||
      raise """
      Bypass.Adapter.Cowboy requires ranch 1.x, but ranch #{ranch_vsn()} is loaded. \
      ranch 2.x removed support for handing the server a pre-opened listen socket, \
      which this adapter relies on. Pin ranch in your deps:

          {:ranch, "~> 1.8", override: true}

      or use the default Bypass.Adapter.Bandit adapter.
      """

    listen_ip = Keyword.fetch!(opts, :listen_ip)
    reuseport_raw = Keyword.fetch!(opts, :reuseport_raw)

    # Pre-open the listen socket ourselves (with SO_REUSEPORT) and hand it to
    # Cowboy. We use `:gen_tcp.listen/2` rather than `:ranch_tcp.listen/1` because
    # the latter's argument shape changed between ranch 1.x (proplist) and 2.x
    # (map); `:gen_tcp` is stable across both.
    {:ok, socket} = :gen_tcp.listen(port, reuseport_raw ++ [ip: listen_ip] ++ @socket_opts)

    cowboy_opts = [
      ref: Keyword.fetch!(opts, :ref),
      port: port,
      transport_options: [num_acceptors: Keyword.fetch!(opts, :num_acceptors), socket: socket]
    ]

    {:ok, _pid} = Plug.Cowboy.http(plug, plug_opts, cowboy_opts)
    {:ok, %{ref: cowboy_opts[:ref], socket: socket}}
  end

  defp ranch_1_x?, do: String.starts_with?(ranch_vsn(), "1.")

  defp ranch_vsn do
    case Application.spec(:ranch, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
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
