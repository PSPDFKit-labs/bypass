defmodule Bypass.Utils do
  @moduledoc false

  Application.load(:bypass)

  if Application.get_env(:bypass, :enable_debug_log, false) do
    defmacro debug_log(msg) do
      quote bind_quoted: [msg: msg] do
        require Logger
        Logger.debug(["[bypass] ", msg])
      end
    end
  else
    defmacro debug_log(_msg) do
      :ok
    end
  end
end
