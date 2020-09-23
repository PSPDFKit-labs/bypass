defmodule Bypass.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Bypass.Supervisor]
    DynamicSupervisor.start_link(opts)
  end
end
