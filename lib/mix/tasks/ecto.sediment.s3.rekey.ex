defmodule Mix.Tasks.Ecto.Sediment.S3.Rekey do
  use Mix.Task

  alias Mix.EctoSediment.Rotation

  @shortdoc "Moves S3-backed Sediment repos to another key of their ring"

  @moduledoc """
  Moves the S3-backed database of each repo to another key of its
  `:encryption` ring, see `Ecto.Adapters.Sediment.s3_rekey/2` and "Rotating
  keys" in the S3 guide.

  **Stop the application first**: a repo running in this VM is refused, and
  a writer elsewhere holds the lease (`--force` fences it). Every node's
  ring needs the new key before the rekey.

  Prints one line per repo. Exits non-zero when any repo's rekey didn't
  succeed: only a success is an outcome (the switch may still happen after
  an error), so keep both keys in every ring and run it again.

  Dynamic repos (tenants started with `name: nil`) aren't visible to Mix:
  use `Ecto.Adapters.Sediment.s3_rekey_many/2` from a release's `eval`.

  ## Examples

      $ mix ecto.sediment.s3.rekey -r MyApp.Repo
      $ mix ecto.sediment.s3.rekey -r MyApp.Repo -r MyApp.OtherRepo --to r3

  ## Command line options

    * `-r`, `--repo` - a repo to rekey (repeatable)
    * `--to` - the key id to move to (default: the ring's active key)
    * `--force` - take the lease even while a writer holds it, fencing it
    * `--allow-reuse` - allow a retired key
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
  """

  @switches [to: :string, force: :boolean, allow_reuse: :boolean]

  @impl true
  def run(args) do
    Rotation.run("ecto.sediment.s3.rekey", args, @switches, fn repo,
                                                               opts,
                                                               _positional ->
      opts = Keyword.take(opts, [:to, :force, :allow_reuse])
      result = Ecto.Adapters.Sediment.s3_rekey(repo, opts)

      case result do
        {:ok, :current} ->
          Rotation.info("#{inspect(repo)}: under the key already")

        {:ok, %{from: from, to: to, epoch: epoch}} ->
          Rotation.info(
            "#{inspect(repo)}: rekeyed from #{from} to #{to} (epoch #{epoch})"
          )

        {:error, reason} ->
          Rotation.error(
            "#{inspect(repo)}: rekey failed: #{Rotation.reason(reason)} " <>
              "(keep both keys in every ring and run it again)"
          )
      end

      result
    end)
  end
end
