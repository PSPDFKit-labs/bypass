defmodule Bypass.Mixfile do
  use Mix.Project

  def project do
    [app: :bypass,
     version: "0.0.1",
     elixir: ">= 1.1.0-rc.0",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :ranch, :cowboy, :plug],
     mod: {Bypass.Application, []}]
  end

  defp deps do
    [
      {:cowboy, "~> 1.0.0"},
      {:plug, "~> 1.0.0"},
    ]
  end
end
