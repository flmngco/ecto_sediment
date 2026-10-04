# Compares ecto_sediment (WAL, MVCC, MVCC+S3) with ecto_sqlite3.
#   mix run run.exs                 # all benchmarks
#   BENCH=insert mix run run.exs    # only benchmarks whose name contains "insert"
#   BENCH_REPOS=Sediment mix run run.exs
Code.require_file("support/setup.exs", __DIR__)

import Ecto.Query

alias Ecto.Bench.{Repos, User}

# Errors are counted per job instead of aborting the whole run
:ets.new(:bench_errors, [:named_table, :public])

count_errors = fn name, fun ->
  fn repo ->
    try do
      fun.(repo)
    rescue
      error ->
        key =
          {name, Repos.label(repo), error |> Exception.message() |> String.split("\n") |> hd()}

        :ets.update_counter(:bench_errors, key, 1, {key, 0})
    end
  end
end

users = fn n -> for _ <- 1..n, do: User.sample_data() end

# Data for the read benchmarks
for repo <- Repos.all(), do: repo.insert_all(User, users.(1_000))

benchmarks = [
  {"insert", "Repo.insert!/1 of one changeset (one commit each)",
   fn repo -> repo.insert!(User.changeset()) end, []},
  {"insert_parallel", "Repo.insert!/1 from 4 processes at once",
   fn repo -> repo.insert!(User.changeset()) end, [parallel: 4]},
  {"insert_all", "Repo.insert_all/2 of 100 rows (one statement, one commit)",
   fn repo -> repo.insert_all(User, users.(100)) end, []},
  {"transaction", "10 Repo.insert!/1 in one Repo.transaction/1",
   fn repo ->
     repo.transaction(fn -> for _ <- 1..10, do: repo.insert!(User.changeset()) end)
   end, []},
  {"all", "Repo.all/2 loading 1000 rows into structs",
   fn repo -> repo.all(from(u in User, limit: 1_000)) end, []},
  {"get", "Repo.get/2 by primary key", fn repo -> repo.get(User, :rand.uniform(1_000)) end, []}
]

only = System.get_env("BENCH")

format_us = fn
  nil -> "-"
  ns when ns >= 1_000_000 -> "#{Float.round(ns / 1_000_000, 2)} ms"
  ns -> "#{Float.round(ns / 1_000, 1)} µs"
end

sections =
  for {name, description, fun, opts} <- benchmarks, only == nil or String.contains?(name, only) do
    IO.puts("\n## #{name}: #{description}\n")

    suite =
      Benchee.run(
        Repos.jobs(count_errors.(name, fun)),
        [warmup: 1, time: String.to_integer(System.get_env("BENCH_TIME", "5"))] ++ opts
      )

    rows =
      suite.scenarios
      |> Enum.sort_by(& &1.run_time_data.statistics.average)
      |> Enum.map(fn %{name: job, run_time_data: %{statistics: s}} ->
        "| #{job} | #{Float.round(s.ips, 1)} | #{format_us.(s.average)} | " <>
          "#{format_us.(s.median)} | #{format_us.(s.percentiles[99])} |"
      end)

    errors =
      for {{^name, job, message}, n} <- :ets.tab2list(:bench_errors),
          do: "* #{job}: #{n} × `#{message}`"

    errors_md =
      if errors == [], do: "", else: "\nErrors during the run:\n\n" <> Enum.join(errors, "\n")

    """
    ### #{name}

    #{description}#{if opts[:parallel], do: " (#{opts[:parallel]} parallel callers)", else: ""}

    | Repo | ops/s | average | median | p99 |
    | ---- | ----: | ------: | -----: | --: |
    #{Enum.join(rows, "\n")}
    #{errors_md}
    """
  end

File.write!(
  Path.expand(System.get_env("BENCH_OUTPUT", "results/latest.md"), __DIR__),
  Enum.join(sections, "\n")
)
