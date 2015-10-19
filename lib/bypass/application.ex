defmodule Bypass.Application do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Bypass.Instance, [], restart: :transient)
    ]

    opts = [strategy: :simple_one_for_one, name: Bypass.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
