tmp = Path.expand("../tmp", __DIR__)
File.rm_rf!(tmp)
File.mkdir_p!(tmp)

s3_prefix = "bench/#{System.os_time(:second)}"

common = [pool_size: 5, log: false]

s3 = fn prefix, extra ->
  [
    bucket: System.get_env("S3_BUCKET", "ecto-tests"),
    prefix: prefix,
    endpoint: System.get_env("S3_ENDPOINT", "http://127.0.0.1:8333"),
    access_key_id: "any",
    secret_access_key: "any",
    owner: "bench"
  ] ++ extra
end

repos = [
  {Ecto.Bench.SQLite3Repo, Ecto.Adapters.SQLite3,
   [database: Path.join(tmp, "sqlite3.db"), journal_mode: :wal]},
  {Ecto.Bench.SQLite3FullRepo, Ecto.Adapters.SQLite3,
   [database: Path.join(tmp, "sqlite3_full.db"), journal_mode: :wal, synchronous: :full]},
  {Ecto.Bench.SedimentWalRepo, Ecto.Adapters.Sediment,
   [database: Path.join(tmp, "sediment_wal.db"), journal_mode: :wal]},
  {Ecto.Bench.SedimentMvccRepo, Ecto.Adapters.Sediment,
   [
     database: Path.join(tmp, "sediment_mvcc.db"),
     journal_mode: :mvcc,
     mvcc_checkpoint_threshold: nil
   ]},
  {Ecto.Bench.SedimentMvccSmallCkptRepo, Ecto.Adapters.Sediment,
   [
     database: Path.join(tmp, "sediment_mvcc_small_ckpt.db"),
     journal_mode: :mvcc
   ]},
  {Ecto.Bench.SedimentMvccIntPkRepo, Ecto.Adapters.Sediment,
   [
     database: Path.join(tmp, "sediment_mvcc_int_pk.db"),
     journal_mode: :mvcc,
     migration_primary_key: [type: :integer]
   ]},
  {Ecto.Bench.SedimentS3Repo, Ecto.Adapters.Sediment,
   [
     database: Path.join(tmp, "sediment_s3.db"),
     s3: s3.(s3_prefix <> "/async", durability: :async),
     encryption: false,
     migration_primary_key: [type: :integer]
   ]},
  {Ecto.Bench.SedimentS3SyncRepo, Ecto.Adapters.Sediment,
   [
     database: Path.join(tmp, "sediment_s3_sync.db"),
     s3: s3.(s3_prefix <> "/sync", durability: :sync),
     encryption: false,
     migration_primary_key: [type: :integer]
   ]}
]

for {repo, adapter, config} <- repos do
  Application.put_env(:ecto_sediment_bench, repo, [adapter: adapter] ++ common ++ config)

  defmodule repo do
    use Ecto.Repo, otp_app: :ecto_sediment_bench, adapter: adapter
  end
end

defmodule Ecto.Bench.Repos do
  @moduledoc false
  @labels %{
    Ecto.Bench.SQLite3Repo => "ecto_sqlite3 WAL (sync=NORMAL)",
    Ecto.Bench.SQLite3FullRepo => "ecto_sqlite3 WAL (sync=FULL)",
    Ecto.Bench.SedimentWalRepo => "ecto_sediment WAL",
    Ecto.Bench.SedimentMvccRepo => "ecto_sediment MVCC (turso_core default checkpoint threshold)",
    Ecto.Bench.SedimentMvccSmallCkptRepo =>
      "ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default)",
    Ecto.Bench.SedimentMvccIntPkRepo => "ecto_sediment MVCC (integer primary key)",
    Ecto.Bench.SedimentS3Repo =>
      "ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS)",
    Ecto.Bench.SedimentS3SyncRepo =>
      "ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS)"
  }

  def all do
    only = System.get_env("BENCH_REPOS")

    @labels
    |> Map.keys()
    |> Enum.filter(&(only == nil or String.contains?(inspect(&1), only)))
    |> Enum.sort()
  end

  def label(repo), do: Map.fetch!(@labels, repo)

  # One Benchee job per repo
  def jobs(fun), do: Map.new(all(), &{label(&1), fn -> fun.(&1) end})
end
