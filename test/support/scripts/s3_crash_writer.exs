# Writes posts to an S3-backed repo, printing each acknowledged commit, then
# halts the VM without closing anything (simulating a crash).
# Usage: mix run --no-compile test/support/scripts/s3_crash_writer.exs <config.term> <count> <sync_every> <flush>
#
# Every <sync_every>th insert (0: none) runs with sync: true and prints
# "committed-sync <i>" instead of "committed <i>". With <flush> = "flush",
# s3_flush/2 runs before the crash and "flushed" is printed once it returned :ok.

alias EctoSediment.DynamicRepo, as: Repo
alias EctoSediment.S3App.Post

[config_path, count, sync_every, flush] = System.argv()
config = config_path |> File.read!() |> :erlang.binary_to_term()
sync_every = String.to_integer(sync_every)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, pid} = Repo.start_link([name: nil, log: false] ++ config)
Repo.put_dynamic_repo(pid)

for i <- 1..String.to_integer(count) do
  sync? = sync_every > 0 and rem(i, sync_every) == 0
  Repo.insert!(%Post{title: "crash-#{i}", views: i}, sync: sync?)
  IO.puts(if(sync?, do: "committed-sync #{i}", else: "committed #{i}"))
end

if flush == "flush" and Ecto.Adapters.Sediment.s3_flush(pid, 10_000) == :ok,
  do: IO.puts("flushed")

# Crash in the middle of a transaction: none of this may survive
Repo.transaction(fn ->
  Repo.insert!(%Post{title: "uncommitted", views: 0})
  IO.puts("in transaction")
  :erlang.halt(0)
end)
