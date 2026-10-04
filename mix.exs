defmodule EctoSediment.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/flmngco/ecto_sediment"

  def project do
    [
      app: :ecto_sediment,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Ecto adapter for Sediment (the Turso database engine, SQLite-compatible), " <>
          "with S3-backed durability. Not affiliated with Turso.",
      package: if(System.get_env("SEDIMENT_HEX"), do: package()),
      source_url: @source_url,
      homepage_url: @source_url,
      test_paths: test_paths(System.get_env("SEDIMENT_INTEGRATION")),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      name: "EctoSediment",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/getting_started.md",
          "guides/s3.md": [title: "S3-backed repos"],
          "guides/migrating_from_ecto_sqlite3.md": [
            title: "Migrating from ecto_sqlite3"
          ],
          "guides/multi_tenant.md": [title: "Multi-tenant apps"],
          "bench/RESULTS.md": [title: "Benchmarks"],
          "CHANGELOG.md": [title: "Changelog"]
        ],
        source_ref: "v#{@version}",
        groups_for_extras: [Guides: ~r"guides/"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, "test.integration": :test]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:decimal, "~> 3.0"},
      {:ecto_sql, "~> 3.14"},
      {:ecto, "~> 3.14"},
      sediment_dep(),
      {:jason, "~> 1.0"},
      {:temp, "~> 0.4", only: [:test]},
      {:oban, "~> 2.19", only: :test},
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: :dev, runtime: false}
    ]
  end

  # A path dependency in a checkout of this repository (it has test/, which
  # the Hex package doesn't). The Hex package, and `SEDIMENT_HEX=1` in a
  # checkout (`mix hex.build`, the release workflow), depend on sediment from
  # Hex: Hex packages can only depend on Hex packages.
  defp sediment_dep do
    if System.get_env("SEDIMENT_HEX") || not File.dir?(Path.join(__DIR__, "test")) do
      {:sediment, "~> 0.1.0"}
    else
      {:sediment, path: System.get_env("SEDIMENT_PATH", "../sediment")}
    end
  end

  defp package do
    [
      name: "ecto_sediment",
      files: ~w(lib guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Sediment" => "https://github.com/flmngco/sediment",
        "ecto_sqlite3" => "https://github.com/elixir-sqlite/ecto_sqlite3"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp test_paths(nil), do: ["test"]
  defp test_paths(_any), do: ["integration_test"]

  defp aliases() do
    [
      "test.integration": [
        "cmd env SEDIMENT_INTEGRATION=true mix test --color",
        "cmd env SEDIMENT_INTEGRATION=true SEDIMENT_JOURNAL_MODE=mvcc mix test --color",
        "cmd env SEDIMENT_INTEGRATION=true SEDIMENT_JOURNAL_MODE=mvcc " <>
          "SEDIMENT_TRANSACTION_MODE=concurrent mix test --color",
        "cmd env SEDIMENT_INTEGRATION=true SEDIMENT_ENCRYPTION_KEY=#{String.duplicate("ab", 32)} " <>
          "mix test --color",
        "cmd env SEDIMENT_INTEGRATION=true SEDIMENT_S3=true mix test --color",
        "cmd env SEDIMENT_INTEGRATION=true SEDIMENT_S3=true SEDIMENT_S3_GROUP_COMMIT=true mix test --color",
        "cmd env SEDIMENT_INTEGRATION=true SEDIMENT_S3=true " <>
          "SEDIMENT_ENCRYPTION_KEY=#{String.duplicate("cd", 32)} mix test --color"
      ],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "test.integration",
        "cmd mix test --only s3_fault --color",
        "credo --strict",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
