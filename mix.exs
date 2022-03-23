defmodule Wasmex.MixProject do
  use Mix.Project

  def project do
    [
      app: :wasmex,
      version: "0.6.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      name: "Wasmex",
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
      {:rustler, "~> 0.24.0"},
      {:ex_doc, "~> 0.28.0", only: [:dev, :test]},
      {:dialyxir, "~> 1.1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp description() do
    "Wasmex is an Elixir library for executing WebAssembly binaries."
  end

  defp package() do
    [
      # These are the default files included in the package
      files:
        ~w(lib native/wasmex/src native/wasmex/Cargo.* native/wasmex/README.md native/wasmex/.cargo .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/tessi/wasmex",
        "Docs" => "https://hexdocs.pm/wasmex"
      },
      source_url: "https://github.com/tessi/wasmex"
    ]
  end
end
