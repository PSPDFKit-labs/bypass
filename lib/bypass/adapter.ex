defmodule Bypass.Adapter do
  @moduledoc """
  Behaviour for pluggable HTTP server backends.

  Bypass ships two adapters:

    * `Bypass.Adapter.Bandit` (default)
    * `Bypass.Adapter.Cowboy` (requires the optional `:plug_cowboy` dependency)

  Select one globally via config:

      config :bypass, adapter: Bypass.Adapter.Cowboy

  An adapter owns the full lifecycle of the underlying HTTP server, including
  any socket / `SO_REUSEPORT` handling, because that differs per backend. The
  `t:handle/0` returned by `c:start/4` is opaque to Bypass and is only ever
  passed back to `c:stop/1`.
  """

  @typedoc "Opaque, adapter-specific server handle stored by `Bypass.Instance`."
  @type handle :: term

  @type opts :: [
          ref: reference,
          listen_ip: :inet.ip_address(),
          num_acceptors: pos_integer,
          reuseport_raw: [term]
        ]

  @callback start(
              plug :: module,
              plug_opts :: keyword,
              port :: :inet.port_number(),
              opts
            ) :: {:ok, handle} | {:error, term}

  @callback stop(handle) :: :ok
end
