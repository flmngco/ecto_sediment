# Every temporary file of a test run (Temp.path!/0, System.tmp_dir!/0, the
# test databases) goes to a per-run directory removed at the end.
# Runs killed before after_suite leave theirs behind: remove those whose OS
# process is gone (Linux, where /proc tells).
if File.dir?("/proc") do
  for dir <- Path.wildcard(Path.join(System.tmp_dir!(), "ecto_sediment_test_*_*")),
      pid = dir |> String.split("_") |> List.last(),
      not File.exists?("/proc/#{pid}"),
      do: File.rm_rf(dir)
end

run_tmp_dir =
  Path.join(System.tmp_dir!(), "ecto_sediment_test_#{System.os_time()}_#{System.pid()}")

File.mkdir_p!(run_tmp_dir)
System.put_env("TMPDIR", run_tmp_dir)
ExUnit.after_suite(fn _ -> File.rm_rf(run_tmp_dir) end)

Logger.configure(level: :info)

Application.put_env(:ecto, :primary_key_type, :id)
Application.put_env(:ecto, :async_integration_tests, false)

ecto = Mix.Project.deps_paths()[:ecto]
ecto_sql = Mix.Project.deps_paths()[:ecto_sql]

Code.require_file("#{ecto_sql}/integration_test/support/repo.exs", __DIR__)

alias Ecto.Integration.TestRepo

# SEDIMENT_JOURNAL_MODE=mvcc runs the suites in MVCC mode (used by S3-backed repos)
journal_mode = String.to_atom(System.get_env("SEDIMENT_JOURNAL_MODE", "wal"))

transaction_mode =
  String.to_atom(System.get_env("SEDIMENT_TRANSACTION_MODE", "deferred"))

# SEDIMENT_ENCRYPTION_KEY=<64 hex chars> runs the suites against encrypted databases;
# S3-backed ones without it opt out of encryption explicitly (S3 requires the choice)
encryption =
  cond do
    key = System.get_env("SEDIMENT_ENCRYPTION_KEY") -> [cipher: "aegis256", key: key]
    System.get_env("SEDIMENT_S3") -> false
    true -> nil
  end

# SEDIMENT_S3=true runs the suites against S3-backed databases (SeaweedFS on :8333)
s3 = fn name ->
  if System.get_env("SEDIMENT_S3") do
    :ok = EctoSediment.S3Helpers.ensure_bucket()

    extra =
      if System.get_env("SEDIMENT_S3_GROUP_COMMIT"), do: [group_commit: true], else: []

    prefix = EctoSediment.S3Helpers.unique_prefix("integration/#{name}")
    EctoSediment.S3Helpers.s3_opts(prefix, "ecto-test", extra)
  end
end

journal_mode = if System.get_env("SEDIMENT_S3"), do: :mvcc, else: journal_mode

Application.put_env(:ecto_sediment, TestRepo,
  adapter: Ecto.Adapters.Sediment,
  database: Path.join(System.tmp_dir!(), "sediment_integration_test.db"),
  journal_mode: journal_mode,
  default_transaction_mode: transaction_mode,
  encryption: encryption,
  s3: s3.("test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  show_sensitive_data_on_connection_error: true
)

# Pool repo for non-async tests
alias Ecto.Integration.PoolRepo

Application.put_env(:ecto_sediment, PoolRepo,
  adapter: Ecto.Adapters.Sediment,
  database: Path.join(System.tmp_dir!(), "sediment_integration_pool_test.db"),
  journal_mode: journal_mode,
  default_transaction_mode: transaction_mode,
  encryption: encryption,
  s3: s3.("pool"),
  show_sensitive_data_on_connection_error: true
)

# needed since some of the integration tests rely on fetching env from :ecto_sql
Application.put_env(:ecto_sql, TestRepo, Application.get_env(:ecto_sediment, TestRepo))
Application.put_env(:ecto_sql, PoolRepo, Application.get_env(:ecto_sediment, PoolRepo))

defmodule Ecto.Integration.PoolRepo do
  use Ecto.Integration.Repo, otp_app: :ecto_sediment, adapter: Ecto.Adapters.Sediment
end

Code.require_file("#{ecto}/integration_test/support/schemas.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/support/migration.exs", __DIR__)

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
  end
end

{:ok, _} = Ecto.Adapters.Sediment.ensure_all_started(TestRepo.config(), :temporary)

# Load up the repository, start it, and run migrations
_ = Ecto.Adapters.Sediment.storage_down(TestRepo.config())
:ok = Ecto.Adapters.Sediment.storage_up(TestRepo.config())

_ = Ecto.Adapters.Sediment.storage_down(PoolRepo.config())
:ok = Ecto.Adapters.Sediment.storage_up(PoolRepo.config())

{:ok, _} = TestRepo.start_link()
{:ok, _pid} = PoolRepo.start_link()

# Unlike ecto_sqlite3, Turso passes :right_join, :like_match_blob, :concat and
# the :selected_as_* tests, so they are not excluded here.
excludes = [
  :delete_with_join,

  # SQLite does not have an array type
  :array_type,
  :transaction_isolation,
  :insert_cell_wise_defaults,
  :insert_select,

  # sqlite does not support microsecond precision, only millisecond
  :microsecond_precision,

  # sqlite supports FKs, but does not return sufficient data
  # for ecto to support matching on a given constraint violation name
  # which is what most of the tests validate
  :foreign_key_constraint,

  # SQLite will return a string for schemaless map types as
  # Ecto does not have enough information to call the associated loader
  # that converts the string JSON representation into a map
  :map_type_schemaless,

  # right now in lock_for_migrations() we do effectively nothing, this is because
  # SQLite is single-writer so there isn't really a need for us to do anything.
  # ecto assumes all implementing adapters need >=2 connections for migrations
  # which is not true for SQLite
  :lock_for_migrations,

  # Migration we don't support
  :prefix,
  :add_column_if_not_exists,
  :remove_column_if_exists,
  :alter_primary_key,
  :alter_foreign_key,
  :assigns_id_type,
  :modify_column,
  :restrict,

  # SQLite does not support placeholders
  :placeholders,

  # SQLite stores booleans as integers, causing Ecto's json_extract_path tests to fail
  :json_extract_path,

  # SQLite does not support ON DELETE SET DEFAULT
  :on_delete_default_all,

  # SQLite doesn't support specifying columns for ON DELETE SET NULL
  :on_delete_nilify_column_list,
  :on_delete_default_column_list,

  # not sure how to support this yet
  :bitstring_type,

  # sqlite does not have a duration type... yet
  :duration_type,

  # SQLite does not support anything except a single column in DISTINCT
  :multicolumn_distinct,

  # Turso: `excluded.<rowid alias>` in an upsert is NULL instead of the would-be
  # new rowid, so `on_conflict: :replace_all` (which sets "id" = EXCLUDED."id")
  # fails with "datatype mismatch". turso_core 0.8.1 engine bug.
  {:location, {"ecto/integration_test/cases/repo.exs", 1917}},
  {:location, {"ecto/integration_test/cases/repo.exs", 1934}},

  # Run all with tag values_list, except for the "delete_all" test,
  # as JOINS are not supported on DELETE statements by SQLite.
  {:location, {"ecto/integration_test/cases/repo.exs", 2281}}
]

# ecto_sql tests use the default 100 ms assert_receive, too tight on a loaded machine
ExUnit.configure(exclude: excludes, assert_receive_timeout: 1_000)

# migrate the pool repo
case Ecto.Migrator.migrated_versions(PoolRepo) do
  [] ->
    :ok = Ecto.Migrator.up(PoolRepo, 0, Ecto.Integration.Migration, log: false)

  _ ->
    :ok = Ecto.Migrator.down(PoolRepo, 0, Ecto.Integration.Migration, log: false)
    :ok = Ecto.Migrator.up(PoolRepo, 0, Ecto.Integration.Migration, log: false)
end

:ok = Ecto.Migrator.up(TestRepo, 0, Ecto.Integration.Migration, log: false)
Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
Process.flag(:trap_exit, true)

ExUnit.start()
