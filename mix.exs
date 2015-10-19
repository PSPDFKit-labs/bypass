defmodule Bypass.Mixfile do
  use Mix.Project

  def project do
    [app: :bypass,
     version: "0.0.1",
     elixir: ">= 1.1.0-rc.0",
     description: description,
     package: package,
     deps: deps]
  end

  def application do
    [applications: [:logger, :ranch, :cowboy, :plug],
     mod: {Bypass.Application, []}]
  end

  defp deps do
    [
      {:cowboy, "~> 1.0.0",},
      {:cowlib, "~> 1.0.1", override: true},
      {:plug, "~> 1.0.0"},
      {:ranch, "~> 1.1.0", override: true},
    ] ++ [
      {:gun, github: "PSPDFKit-labs/gun", only: :test},
    ]
  end

  defp description do
    """
    Bypass provides a quick way to create a custom plug that can be put in place instead of an
    actual HTTP server to return prebaked responses to client requests. This is most useful in
    tests, when you want to create a mock HTTP server and test how your HTTP client handles
    different types of responses from the server.
    """
  end

  defp package do
    [
      files: ["lib", "priv", "mix.exs", "README*", "readme*", "LICENSE*", "license*"],
      maintainers: ["PSPDFKit GmbH"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/pspdfkit-labs/bypass"}
    ]
  end
end
