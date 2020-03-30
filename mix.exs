defmodule Bypass.Mixfile do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/PSPDFKit-labs/bypass"

  def project do
    [
      app: :bypass,
      version: @version,
      elixir: "~> 1.6",
      description: description(),
      package: package(),
      deps: deps(Mix.env()),
      docs: docs()
    ]
  end

  def application do
    [
      applications: [:logger, :ranch, :cowboy, :plug, :plug_cowboy],
      mod: {Bypass.Application, []},
      env: env()
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 1.0 or ~> 2.0"},
      {:plug, "~> 1.7"},
      {:ex_doc, "> 0.0.0", only: :dev},
      {:espec, "~> 1.6", only: [:dev, :test]}
    ]
  end

  defp env do
    [enable_debug_log: false]
  end

  # We need to work around the fact that gun would pull in cowlib/ranch from git, while cowboy/plug
  # depend on them from hex. In order to resolv this we need to override those dependencies. But
  # since you can't publish to hex with overriden dependencies this ugly hack only pulls the
  # dependencies in when in the test env.
  defp deps(:test) do
    deps() ++
      [
        {:cowlib, "~> 1.0.1", override: true},
        {:ranch, "~> 1.2.0", override: true},
        {:gun, github: "PSPDFKit-labs/gun", only: :test}
      ]
  end

  defp deps(_), do: deps()

  defp docs do
    [
      main: "Bypass",
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp description do
    """
    Bypass provides a quick way to create a custom plug that can be put in place instead of an
    actual HTTP server to return prebaked responses to client requests. This is helpful when you
    want to create a mock HTTP server and test how your HTTP client handles different types of
    server responses.
    """
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["PSPDFKit"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "PSPDFKit" => "https://pspdfkit.com"
      }
    ]
  end
end
