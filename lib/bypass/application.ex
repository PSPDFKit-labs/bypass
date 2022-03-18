defmodule Bypass.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      Bypass.FreePort,
      {DynamicSupervisor, strategy: :one_for_one, name: Bypass.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
