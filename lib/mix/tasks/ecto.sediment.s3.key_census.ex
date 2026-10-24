defmodule Mix.Tasks.Ecto.Sediment.S3.KeyCensus do
  use Mix.Task

  alias Mix.EctoSediment.Rotation

  @shortdoc "Lists the keys S3-backed Sediment repos depend on"

  @moduledoc """
  Prints, for each repo, the key its S3-backed database is under and the
  keys of its retained epochs, see `Ecto.Adapters.Sediment.s3_key_census/1`.
  A key can leave the rings once no repo lists it. It reads manifests
  only: safe while the application runs.

  Exits non-zero when a repo's manifest can't be read.

  ## Examples

      $ mix ecto.sediment.s3.key_census -r MyApp.Repo

  ## Command line options

    * `-r`, `--repo` - a repo (repeatable)
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @impl true
  def run(args) do
    Rotation.run("ecto.sediment.s3.key_census", args, [], fn repo, _opts, _positional ->
      result = Ecto.Adapters.Sediment.s3_key_census(repo)

      case result do
        {:ok, :no_database} ->
          Rotation.info("#{inspect(repo)}: no database")

        {:ok, %{current: current, retained: retained}} ->
          Rotation.info(
            "#{inspect(repo)}: current #{current || "none (unencrypted)"}; " <>
              "retained: #{retained(retained)}"
          )

        {:error, reason} ->
          Rotation.error("#{inspect(repo)}: census failed: #{Rotation.reason(reason)}")
      end

      result
    end)
  end

  defp retained(retained) when retained == %{}, do: "none"

  defp retained(retained),
    do:
      Enum.map_join(retained, ", ", fn {key, epochs} ->
        "#{key} (#{length(epochs)} epochs)"
      end)
end
