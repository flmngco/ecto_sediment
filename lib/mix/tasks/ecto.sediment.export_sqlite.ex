defmodule Mix.Tasks.Ecto.Sediment.ExportSqlite do
  use Mix.Task

  import Mix.Ecto

  @shortdoc "Exports a Sediment repo's database to a plain SQLite file"

  @aliases [r: :repo, o: :output, s: :source, q: :quiet]
  @switches [
    repo: [:string, :keep],
    output: :string,
    source: :string,
    drop_fts: :boolean,
    quiet: :boolean,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @moduledoc """
  Exports a repo's database to a new plain SQLite file, the way back from
  Sediment to SQLite (ecto_sqlite3); see `Ecto.Adapters.Sediment.export_sqlite/3`
  and sediment's "Leaving Sediment" guide.

  An S3 repo is exported from its S3 prefix (only read, so the application
  may keep running), with the repo's `:encryption`; another repo from its
  `:database` file (stop the application first). The output is checked
  (integrity, row counts, AUTOINCREMENT sequences) before it is written.

  ## Examples

      $ mix ecto.sediment.export_sqlite -r MyApp.Repo -o /tmp/app-sqlite.db
      $ mix ecto.sediment.export_sqlite -r MyApp.Repo -o /tmp/app-sqlite.db --source /backups/app.db
      $ mix ecto.sediment.export_sqlite -r MyApp.Repo -o /tmp/app-sqlite.db --drop-fts

  ## Command line options

    * `-r`, `--repo` - the repo whose configuration is used
    * `-o`, `--output` - the SQLite file to write (required); it must not
      exist
    * `-s`, `--source` - export this database file instead of the repo's
    * `--drop-fts` - leave Turso FTS indexes out (SQLite can't read them);
      without it a database with any is refused
    * `-q`, `--quiet` - run the command quietly
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    output =
      opts[:output] || Mix.raise("ecto.sediment.export_sqlite needs --output PATH")

    Mix.Task.run("app.config", args)
    {:ok, _} = Application.ensure_all_started(:sediment)

    case parse_repo(args) do
      [repo] -> export(repo, output, opts)
      _ -> Mix.raise("ecto.sediment.export_sqlite needs exactly one repo (-r)")
    end
  end

  defp export(repo, output, opts) do
    ensure_repo(repo, [])
    export_opts = [source: opts[:source], drop_fts: opts[:drop_fts] == true]

    case Ecto.Adapters.Sediment.export_sqlite(repo, output, export_opts) do
      {:ok, info} ->
        unless opts[:quiet] do
          Mix.shell().info("Exported #{inspect(repo)} to #{output}: #{inspect(info)}")
        end

      {:error, reason} ->
        Mix.raise("Export of #{inspect(repo)} failed: #{format_error(reason)}")
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
