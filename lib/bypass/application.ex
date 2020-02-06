defmodule Bypass.Application do
  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Bypass.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Bypass.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
