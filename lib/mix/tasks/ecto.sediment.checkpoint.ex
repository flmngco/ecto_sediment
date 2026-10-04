defmodule Mix.Tasks.Ecto.Sediment.Checkpoint do
  use Mix.Task

  import Mix.Ecto

  @shortdoc "Checkpoints Sediment repos (uploads an S3 snapshot for S3-backed repos)"

  @aliases [r: :repo, q: :quiet]
  @switches [
    repo: [:string, :keep],
    quiet: :boolean,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @moduledoc """
  Checkpoints the database of the given repository, see
  `Ecto.Adapters.Sediment.checkpoint/2`.

  For S3-backed repos this uploads a snapshot of the database to S3 (only the
  segments changed since the previous one).
  The repo is started for the duration of the task, so for S3-backed repos it
  must not be running elsewhere (the writer lease is exclusive).

  ## Example

      $ mix ecto.sediment.checkpoint -r MyApp.Repo

  ## Command line options

    * `-r`, `--repo` - the repo to checkpoint
    * `-q`, `--quiet` - run the command quietly
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    Mix.Task.run("app.config", args)

    for repo <- parse_repo(args) do
      ensure_repo(repo, args)

      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Adapters.Sediment.checkpoint/1,
          pool_size: 1
        )

      report(repo, result, opts)
    end
  end

  defp report(repo, :ok, opts) do
    unless opts[:quiet], do: Mix.shell().info("Checkpointed #{inspect(repo)}")
  end

  defp report(repo, {:error, error}, _opts) do
    Mix.raise("Checkpoint of #{inspect(repo)} failed: #{Exception.message(error)}")
  end
end
