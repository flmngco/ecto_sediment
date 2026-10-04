defmodule EctoSedimentBench.MixProject do
  use Mix.Project

  # A separate project so ecto_sqlite3/exqlite never become deps of ecto_sediment.
  def project do
    [app: :ecto_sediment_bench, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:ecto_sediment, path: ".."},
      {:ecto_sqlite3, "~> 0.25"},
      {:benchee, "~> 1.3"}
    ]
  end
end
