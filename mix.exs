defmodule Wasmex.MixProject do
  use Mix.Project

  @version "0.15.0"

  def project do
    [
      app: :wasmex,
      version: @version,
      elixir: "~> 1.18",
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
      {:rustler_precompiled, "~> 0.9"},
      {:rustler, "~> 0.38"},
      {:ex_doc, "~> 0.40.3", only: [:dev, :test]},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false}
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
        logo.svg
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
