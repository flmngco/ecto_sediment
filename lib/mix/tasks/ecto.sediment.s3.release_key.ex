defmodule Mix.Tasks.Ecto.Sediment.S3.ReleaseKey do
  use Mix.Task

  alias Mix.EctoSediment.Rotation

  @shortdoc "Drops the epochs of S3-backed Sediment repos under a retired key"

  @moduledoc """
  Drops the retained epochs of each repo's S3-backed database encrypted
  under `KEY_ID`, see `Ecto.Adapters.Sediment.s3_release_key/3`: afterwards
  point-in-time restore no longer reaches them, and once
  `mix ecto.sediment.s3.key_census` no longer lists the key, it can leave
  the rings.

  **Stop the application first**, on every node, as for
  `mix ecto.sediment.s3.rekey` (the task's own VM doesn't see it; its lease
  makes the release fail with `"s3 lease held by ..."`). The
  current key is refused (rekey first).

  Prints one line per repo and exits non-zero when any repo's release
  didn't succeed (run it again).

  A repo whose S3 location holds no database prints `no database at
  <bucket>/<prefix>: wrong bucket or prefix?` and fails the task.

  ## Examples

      $ mix ecto.sediment.s3.release_key r1 -r MyApp.Repo

  ## Command line options

    * `-r`, `--repo` - a repo (repeatable)
    * `--force` - take the lease even while a writer holds it, fencing it:
      under `durability: :async` its acknowledged commits not yet uploaded
      are lost. Only for a holder known to be gone (a crashed run), never
      for a running application
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @switches [force: :boolean]

  @impl true
  def run(args) do
    Rotation.run("ecto.sediment.s3.release_key", args, @switches, fn repo,
                                                                     opts,
                                                                     positional ->
      key_id =
        case positional do
          [key_id] -> key_id
          _ -> Mix.raise("ecto.sediment.s3.release_key needs one KEY_ID")
        end

      result =
        Ecto.Adapters.Sediment.s3_release_key(
          repo,
          key_id,
          Keyword.take(opts, [:force])
        )

      if Rotation.absent?(result),
        do: Rotation.absent(repo),
        else: report(repo, key_id, result)

      result
    end)
  end

  defp report(repo, key_id, result) do
    case result do
      {:ok, %{epochs: []}} ->
        Rotation.info("#{inspect(repo)}: no epoch under key #{key_id}")

      {:ok, %{key: key, epochs: epochs}} ->
        Rotation.info(
          "#{inspect(repo)}: released key #{key} (#{length(epochs)} epochs dropped)"
        )

      {:error, reason} ->
        Rotation.error(
          "#{inspect(repo)}: release failed: #{Rotation.reason(reason)} " <>
            "(keep the key in every ring and run it again)"
        )
    end
  end
end
