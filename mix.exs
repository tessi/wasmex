defmodule Wasmex.MixProject do
  use Mix.Project

  @version "0.9.1"

  def project do
    [
      app: :wasmex,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      name: "wasmex",
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler_precompiled, "~> 0.8.1"},
      {:rustler, "~> 0.34.0"},
      {:ex_doc, "~> 0.34.1", only: [:dev, :test]},
      {:credo, "~> 1.7.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp description() do
    "Wasmex is an Elixir library for executing WebAssembly binaries"
  end

  defp package() do
    [
      # These are the default files included in the package
      files: ~w[
        lib
        native/wasmex/src
        native/wasmex/Cargo.*
        native/wasmex/README.md
        native/wasmex/.cargo
        checksum-Elixir.Wasmex.Native.exs
        .formatter.exs
        mix.exs
        README.md
        LICENSE.md
        CHANGELOG.md
        ],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/tessi/wasmex",
        "Docs" => "https://hexdocs.pm/wasmex"
      },
      source_url: "https://github.com/tessi/wasmex"
    ]
  end
end
