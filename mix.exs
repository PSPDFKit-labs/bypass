defmodule Bypass.Mixfile do
  use Mix.Project

  @version "3.0.0"
  @source_url "https://github.com/PSPDFKit-labs/bypass"

  def project do
    [
      app: :bypass,
      version: @version,
      elixir: "~> 1.15",
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  defp aliases do
    # `mix test.adapters` runs the suite against both HTTP backends, each in a
    # fresh VM. Extra args are forwarded, e.g. `mix test.adapters --seed 0`.
    ["test.adapters": &test_adapters/1]
  end

  defp test_adapters(args) do
    statuses =
      for adapter <- ~w(bandit cowboy) do
        IO.puts(IO.ANSI.format([:cyan, "\n==> mix test with BYPASS_ADAPTER=#{adapter}\n"]))

        {_, status} =
          System.cmd("mix", ["test" | args],
            env: [{"BYPASS_ADAPTER", adapter}],
            into: IO.stream(:stdio, :line)
          )

        status
      end

    if Enum.any?(statuses, &(&1 != 0)), do: exit({:shutdown, 1})
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Bypass.Application, []},
      env: env()
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug_cowboy, "~> 2.0", optional: true},
      # Pinned to ranch 1.x: the Cowboy adapter hands ranch a pre-opened listen
      # socket (for SO_REUSEPORT), an option ranch 2.x removed. A non-optional
      # dep constrains a consumer's resolution, so pinning here keeps the Cowboy
      # adapter working without every consumer needing an `override: true`.
      {:ranch, "~> 1.8"},
      {:plug, "~> 1.14"},
      {:ex_doc, "> 0.0.0", only: :dev},
      {:espec, "~> 1.6", only: [:dev, :test]},
      {:mint, "~> 1.1", only: :test},
      {:dialyxir, "~> 1.3", only: [:dev], runtime: false}
    ]
  end

  defp env do
    [enable_debug_log: false]
  end

  defp docs do
    [
      main: "Bypass",
      api_reference: false,
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["CHANGELOG.md"]
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
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"],
      maintainers: ["PSPDFKit"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "GitHub" => @source_url,
        "PSPDFKit" => "https://pspdfkit.com"
      }
    ]
  end
end
