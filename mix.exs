defmodule Wasmex.MixProject do
  use Mix.Project

  @version "0.11.1"

  def project do
    [
      app: :wasmex,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.36.1"},
      {:ex_doc, "~> 0.38.0", only: [:dev, :test]},
      {:credo, "~> 1.7.11", only: [:dev, :test], runtime: false}
    ]
  end

  defp description() do
    "Wasmex is an Elixir library for executing WebAssembly binaries"
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/component_fixtures"]
  defp elixirc_paths(_), do: ["lib"]

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
