# Shows how MVCC write latency grows with the un-checkpointed log and
# recovers after a checkpoint:
#   BENCH_REPOS=SedimentMvccRepo SEQ=5000 mix run mvcc_log_growth.exs
# (PROBE_REPO names the repo to measure, SedimentMvccRepo by default; SEQ the
# number of sequential inserts first)
Code.require_file("support/setup.exs", __DIR__)
alias Ecto.Bench.User
repo = Module.concat(Ecto.Bench, System.get_env("PROBE_REPO", "SedimentMvccRepo"))
seq = String.to_integer(System.get_env("SEQ", "0"))
{t, _} = :timer.tc(fn -> for _ <- 1..seq, do: repo.insert!(User.changeset()) end)
IO.puts("sequential #{seq}: #{div(t, 1000)} ms")

for round <- 1..6 do
  if round == 4 do
    {t, r} = :timer.tc(fn -> Ecto.Adapters.Sediment.checkpoint(repo) end)
    IO.puts("checkpoint: #{div(t, 1000)} ms #{inspect(r)}")
  end

  {t, errors} =
    :timer.tc(fn ->
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          for _ <- 1..100,
              do:
                (try do
                   repo.insert!(User.changeset())
                   :ok
                 rescue
                   e -> {:error, Exception.message(e) |> String.split("\n") |> hd()}
                 end)
        end)
      end)
      |> Enum.flat_map(&Task.await(&1, :infinity))
      |> Enum.reject(&(&1 == :ok))
    end)

  IO.puts(
    "parallel round #{round} (400 inserts): #{div(t, 1000)} ms #{inspect(Enum.frequencies(errors))}"
  )
end

IO.inspect(
  File.ls!(Path.expand("tmp", __DIR__))
  |> Enum.map(&{&1, File.stat!(Path.join(Path.expand("tmp", __DIR__), &1)).size})
)
