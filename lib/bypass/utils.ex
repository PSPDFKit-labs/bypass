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
end
