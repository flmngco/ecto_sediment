defmodule Mix.Tasks.Ecto.Sediment.S3.Rekey do
  use Mix.Task

  alias Mix.EctoSediment.Rotation

  @shortdoc "Moves S3-backed Sediment repos to another key of their ring"

  @moduledoc """
  Moves the S3-backed database of each repo to another key of its
  `:encryption` ring, see `Ecto.Adapters.Sediment.s3_rekey/2` and "Rotating
  keys" in the S3 guide.

  **Stop the application first**, on every node. The task runs in a VM of
  its own, which doesn't see the application: a running application holds
  the database's lease, and the rekey fails with `"s3 lease held by <owner>
  ..."`, naming the node to stop. Every node's ring needs the new key
  before the rekey.

  Prints one line per repo. Exits non-zero when any repo's rekey didn't
  succeed: only a success is an outcome (the switch may still happen after
  an error), so keep both keys in every ring and run it again.

  Dynamic repos (tenants started with `name: nil`) aren't visible to Mix:
  use `Ecto.Adapters.Sediment.s3_rekey_many/2` inside the live node
  (`bin/my_app rpc`), or from `bin/my_app eval` with the application
  stopped (see "Rotating keys" in the S3 guide).

  A repo whose S3 location holds no database prints `no database at
  <bucket>/<prefix>: wrong bucket or prefix?` and fails the task.

  ## Examples

      $ mix ecto.sediment.s3.rekey -r MyApp.Repo
      $ mix ecto.sediment.s3.rekey -r MyApp.Repo -r MyApp.OtherRepo --to r3

  ## Command line options

    * `-r`, `--repo` - a repo to rekey (repeatable)
    * `--to` - the key id to move to (default: the ring's active key)
    * `--force` - take the lease even while a writer holds it, fencing it:
      under `durability: :async` its acknowledged commits not yet uploaded
      are lost. Only for a holder known to be gone (a crashed run), never
      for a running application
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

      if Rotation.absent?(result), do: Rotation.absent(repo), else: report(repo, result)

      result
    end)
  end

  defp report(repo, result) do
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
  end
end
