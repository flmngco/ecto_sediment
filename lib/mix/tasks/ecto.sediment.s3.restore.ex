defmodule Mix.Tasks.Ecto.Sediment.S3.Restore do
  use Mix.Task

  import Mix.Ecto

  @shortdoc "Restores an S3-backed Sediment repo into a standalone database file"

  @aliases [r: :repo, o: :output, q: :quiet]
  @switches [
    repo: [:string, :keep],
    output: :string,
    at: :string,
    epoch: :string,
    epoch_start: :string,
    quiet: :boolean,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @moduledoc """
  Restores the S3-backed database of a repo into a standalone file, see
  `Ecto.Adapters.Sediment.s3_restore/3`.

  The restore only reads from S3, so it is safe while the application is
  running. For an encrypted repo the repo's `:encryption` option is used and
  the restored file stays encrypted with the same key. Use it for point-in-time recovery, to inspect an old state, or to
  take a local copy.

  ## Examples

      $ mix ecto.sediment.s3.restore -r MyApp.Repo -o /tmp/latest.db
      $ mix ecto.sediment.s3.restore -r MyApp.Repo -o /tmp/before.db --at 2026-09-29T21:00:00Z
      $ mix ecto.sediment.s3.restore -r MyApp.Repo -o /tmp/epoch3.db --epoch 3
      $ mix ecto.sediment.s3.restore -r MyApp.Repo -o /tmp/start.db --epoch-start 00000000000000000003-0000000002

  ## Command line options

    * `-r`, `--repo` - the repo whose `:s3` configuration is used
    * `-o`, `--output` - the file to restore into (required). It must not
      exist: the task never replaces a file
    * `--at` - an ISO 8601 timestamp: restore the state as of that moment
    * `--epoch` - restore an epoch, all of it (its snapshot and its whole
      log): its sequence number, or the epoch as results print it
      (`SEQ-GENERATION`)
    * `--epoch-start` - restore an epoch's snapshot alone, the state at its
      start (the epoch as for `--epoch`)
    * `-q`, `--quiet` - run the command quietly
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    output = opts[:output] || Mix.raise("ecto.sediment.s3.restore needs --output PATH")
    Mix.Task.run("app.config", args)
    {:ok, _} = Application.ensure_all_started(:sediment)

    case parse_repo(args) do
      [repo] -> restore(repo, output, opts)
      _ -> Mix.raise("ecto.sediment.s3.restore needs exactly one repo (-r)")
    end
  end

  defp restore(repo, output, opts) do
    ensure_repo(repo, [])

    case Ecto.Adapters.Sediment.s3_restore(repo, output, restore_opts(opts)) do
      {:ok, info} ->
        unless opts[:quiet] do
          Mix.shell().info("Restored #{inspect(repo)} into #{output}: #{inspect(info)}")
        end

      {:error, reason} ->
        Mix.raise("Restore of #{inspect(repo)} failed: #{format_error(reason)}")
    end
  end

  defp restore_opts(opts) do
    cond do
      at = opts[:at] -> [at: parse_datetime!(at)]
      epoch = opts[:epoch] -> [epoch: parse_epoch(epoch)]
      epoch = opts[:epoch_start] -> [epoch_start: parse_epoch(epoch)]
      true -> []
    end
  end

  # A sequence number, or the epoch as results print it (passed on as is:
  # sediment parses it, and refuses any other form).
  defp parse_epoch(epoch) do
    case Integer.parse(epoch) do
      {seq, ""} -> seq
      _ -> epoch
    end
  end

  defp parse_datetime!(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> Mix.raise("--at must be an ISO 8601 timestamp, got: #{string}")
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
