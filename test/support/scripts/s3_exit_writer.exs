# Starts an S3-backed repo, inserts <count> posts (async durability: each
# returns once committed locally), prints "acked <count>" and ends like any
# script or Mix task: Elixir's CLI halts the VM without stopping the repo.
# Usage: mix run --no-compile --no-deps-check --no-start s3_exit_writer.exs <config.term> <count>

alias EctoSediment.DynamicRepo, as: Repo
alias EctoSediment.S3App.Post

[config_path, count] = System.argv()
config = config_path |> File.read!() |> :erlang.binary_to_term()

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, pid} = Repo.start_link([name: nil, log: false] ++ config)
Repo.put_dynamic_repo(pid)

count = String.to_integer(count)
for i <- 1..count, do: Repo.insert!(%Post{title: "exit-#{i}"})
IO.puts("acked #{count}")
