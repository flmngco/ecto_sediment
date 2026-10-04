defmodule Mix.Tasks.Ecto.Sediment.S3.Import do
  use Mix.Task

  import Mix.Ecto

  @shortdoc "Imports an existing database file into an S3-backed Sediment repo's empty prefix"

  @aliases [r: :repo, s: :source, q: :quiet]
  @switches [
    repo: [:string, :keep],
    source: :string,
    verify: :string,
    quiet: :boolean,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @moduledoc """
  Imports an existing database file (SQLite or Sediment) as the new database
  of a repo's empty S3 prefix, see `Ecto.Adapters.Sediment.s3_import/3`: its
  schema and rows (AUTOINCREMENT sequences, indexes, views, triggers and
  foreign keys included) are copied into a new MVCC database and uploaded.
  The new database is encrypted with the repo's `:encryption` key (an
  encrypted source is read with it too), or unencrypted with
  `encryption: false`; S3 repos need one of the two.

  Run it with the application stopped: changes made to the file during or
  after the import aren't in S3. The file is never written to; when the repo
  starts with its `:s3` configuration, it restores the imported database
  over it.

  ## Examples

      $ mix ecto.sediment.s3.import -r MyApp.Repo
      $ mix ecto.sediment.s3.import -r MyApp.Repo --source /backups/app.db --verify restore

  ## Command line options

    * `-r`, `--repo` - the repo whose `:s3` configuration is used
    * `-s`, `--source` - the database file to import; defaults to the repo's
      `:database`
    * `--verify` - `checksum` (default) or `restore` (also downloads the
      imported database and compares)
    * `-q`, `--quiet` - run the command quietly
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    Mix.Task.run("app.config", args)
    {:ok, _} = Application.ensure_all_started(:sediment)

    case parse_repo(args) do
      [repo] -> import_into(repo, opts)
      _ -> Mix.raise("ecto.sediment.s3.import needs exactly one repo (-r)")
    end
  end

  defp import_into(repo, opts) do
    ensure_repo(repo, [])

    case Ecto.Adapters.Sediment.s3_import(repo, opts[:source],
           verify: verify(opts[:verify])
         ) do
      {:ok, info} ->
        report(repo, info, opts)

      {:error, reason} ->
        Mix.raise("Import into #{inspect(repo)} failed: #{format_error(reason)}")
    end
  end

  defp verify(nil), do: :checksum
  defp verify("checksum"), do: :checksum
  defp verify("restore"), do: :restore

  defp verify(other),
    do: Mix.raise("--verify must be checksum or restore, got: #{other}")

  defp report(repo, info, opts) do
    for table <- info.sequences_not_advanced do
      Mix.shell().info(
        "warning: the AUTOINCREMENT sequence of #{table} (an emptied table whose CHECK " <>
          "constraints refuse a placeholder row) starts again at 1"
      )
    end

    unless opts[:quiet] do
      Mix.shell().info(
        "Imported #{opts[:source] || "the database"} into #{inspect(repo)}'s S3 prefix: #{inspect(info)}"
      )
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
