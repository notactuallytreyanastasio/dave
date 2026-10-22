defmodule ElixirHost.MixProject do
  use Mix.Project

  # A host-side probe: drives the generated Temper.Dave.RepairAgent from
  # plain Elixir, with path deps on the three mix projects the Elixir
  # backend writes. `bin/temper-elixir build -b elixir` first.
  def project do
    [
      app: :elixir_host,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:temper_core, path: "../../temper.out/elixir/temper-core"},
      {:temper_std, path: "../../temper.out/elixir/std"},
      {:temper_dave, path: "../../temper.out/elixir/dave"},
      {:jason, "~> 1.4"}
    ]
  end
end
