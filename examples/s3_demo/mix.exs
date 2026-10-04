defmodule S3Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :s3_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl], mod: {S3Demo.Application, []}]
  end

  defp deps do
    [{:ecto_sediment, path: "../.."}]
  end

  defp aliases do
    [setup: ["demo.bucket", "ecto.create", "ecto.migrate"]]
  end
end
