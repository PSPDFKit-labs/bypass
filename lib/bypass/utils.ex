defmodule Bypass.Utils do
  @moduledoc false

  Application.load(:bypass)

  defmacro debug_log(msg) do
    quote bind_quoted: [msg: msg] do
      if Application.get_env(:bypass, :enable_debug_log, false) do
        require Logger
        Logger.debug(["[bypass] ", msg])
      else
        :ok
      end
    end
  end

  # Use raw socket options to set SO_REUSEPORT so we fix {:error, :eaddrinuse} - where the OS errors
  # when we attempt to listen on the same port as before, since it's still considered in use.
  #
  # See https://lwn.net/Articles/542629/ for details on SO_REUSEPORT.
  #
  # See https://github.com/aetrion/erl-dns/blob/0c8d768/src/erldns_server_sup.erl#L81 for an
  # Erlang library using this approach.
  #
  # We want to do this:
  #
  #     int optval = 1;
  #     setsockopt(sfd, SOL_SOCKET, SO_REUSEPORT, &optval, sizeof(optval));
  #
  # Use the following C program to find the values on each OS:
  #
  #     #include <stdio.h>
  #     #include <sys/socket.h>
  #
  #     int main() {
  #         printf("SOL_SOCKET: %d\n", SOL_SOCKET);
  #         printf("SO_REUSEPORT: %d\n", SO_REUSEPORT);
  #         return 0;
  #     }
  def so_reuseport() do
    case :os.type() do
      {:unix, :linux} -> [{:raw, 1, 15, <<1::32-native>>}]
      {:unix, :darwin} -> [{:raw, 65_535, 512, <<1::32-native>>}]
      _ -> []
    end
  end
end
