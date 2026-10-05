# EctoSediment

Ecto adapter for Sediment, the SQLite-compatible database for Elixir on the
[Turso](https://github.com/tursodatabase/turso) engine (in-process, written in
Rust), with optional S3-backed durability. Uses `sediment` as the driver.
Both are experimental: expect rough edges, and keep backups.

## Naming

Why not `ecto_turso`? See
[the Naming section in Sediment's README](https://github.com/flmngco/sediment#naming):
we love Turso and don't want to ride on their name, and this project is
experimental, so its integration mistakes are ours, not Turso's. Turso Cloud
doesn't work with it right now.

> **Not affiliated with Turso.** Sediment is an independent, community-maintained Elixir library built on the open-source Turso database engine (`turso_core`, MIT). "Turso" is a trademark of its respective owner and is used here only to describe compatibility. This project is not endorsed by, sponsored by, or otherwise connected with Turso or its company.
>
> Provided under the MIT License, without warranty of any kind. The underlying engine is pre-1.0; keep independent backups of any data you care about.

`ecto_sediment` is a port of [`ecto_sqlite3`](https://github.com/elixir-sqlite/ecto_sqlite3):
the options, generated SQL, types and migrations are the same, so switching an
application over is usually a one-line change of the adapter module. Where
Turso behaves differently the difference is listed below, and Turso-only
features (vectors, concurrent transactions, S3-backed databases, encryption)
are exposed as extensions.

Guides: [Getting started](guides/getting_started.md),
[S3-backed repos](guides/s3.md) (configuration, releases, deploys with the
single-writer lease), [Migrating from ecto_sqlite3](guides/migrating_from_ecto_sqlite3.md),
[Multi-tenant apps](guides/multi_tenant.md) (one database per tenant).

Contents: [Installation](#installation) · [Usage](#usage) ·
[Migrating from ecto_sqlite3](#migrating-from-ecto_sqlite3) ·
[Turso extensions](#turso-extensions) (vectors, full-text search, concurrent
transactions, encryption, S3-backed databases) · [Oban](#oban) ·
[Type Extensions](#type-extensions) · [ecto_sqlite3 parity](#ecto_sqlite3-parity) ·
[Differences from ecto_sqlite3](#differences-from-ecto_sqlite3) ·
[Benchmarks](#benchmarks) · [Running Tests](#running-tests)

## Installation

```elixir
defp deps do
  [
    {:ecto_sediment, "~> 0.1"}
  ]
end
```

ecto_sediment brings in `sediment`, the driver, and needs Elixir 1.18+
(OTP 27+). The driver's NIF is downloaded precompiled for Linux (glibc and
musl, x86_64 and aarch64), macOS (Apple silicon and Intel) and Windows
(x86_64), so no Rust toolchain is needed (on Linux, glibc 2.28 or later, or
musl). On other targets, or to build from source anyway, set
`SEDIMENT_BUILD=1` and install Rust 1.91 or later; a git or path dependency
on sediment always builds from source. See sediment's README.

### With Igniter

In a project that uses [Igniter](https://hexdocs.pm/igniter), the installer
adds the dependency, creates `MyApp.Repo`, adds it to the supervision tree and
configures it the way Phoenix configures ecto_sqlite3 repos (a local file in
dev and test with the SQL sandbox, `DATABASE_PATH` in `config/runtime.exs`
for prod):

```sh
mix igniter.install ecto_sediment
mix igniter.install ecto_sediment --s3   # prod repo backed by S3 (env vars), integer primary keys
```

If ecto_sediment is already a dependency, run `mix ecto_sediment.install` (options
`--repo MyApp.OtherRepo`, `--s3`).

## Usage

Define your repo similar to this.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Sediment
end
```

Configure your repository similar to the following. See
`Ecto.Adapters.Sediment` for all available options.

```elixir
config :my_app,
  ecto_repos: [MyApp.Repo]

config :my_app, MyApp.Repo,
  database: "path/to/my/database.db"
```

## Migrating from ecto_sqlite3

Swap the dependency and the adapter module, move the `config :ecto_sqlite3`
settings to `config :ecto_sediment`, and rename the type extension behaviours;
existing SQLite database files open directly. The steps and the repo options
that behave differently are in the
[migration guide](guides/migrating_from_ecto_sqlite3.md).

## Turso extensions

### Vectors

Turso has native vector support. `Ecto.Adapters.Sediment.Vector` (32-bit floats)
and `Ecto.Adapters.Sediment.Vector64` (64-bit floats) are Ecto types that store
lists of numbers as Turso vector blobs, and `Ecto.Adapters.Sediment.Vector.Query`
has macros for Turso's distance functions.

```elixir
# migration
create table(:documents) do
  add :content, :string
  add :embedding, :vector32, size: 3   # F32_BLOB(3); :vector64 -> F64_BLOB(n)
end

# schema
schema "documents" do
  field :content, :string
  field :embedding, Ecto.Adapters.Sediment.Vector
end

# query
import Ecto.Adapters.Sediment.Vector.Query

Repo.all(
  from d in Document,
    order_by: vector_distance_cos(d.embedding, ^[0.1, 0.2, 0.3]),
    limit: 5
)
```

Available macros: `vector_distance_cos/2`, `vector_distance_l2/2`,
`vector_distance_dot/2`, `vector_distance_jaccard/2` and `vector_extract/1`.
Pinned lists are converted to `vector32` blobs automatically.

### Full-text search

Turso's full-text search (Tantivy-based, not SQLite FTS5) is an
experimental feature, enabled with `experimental: [:index_method]` in the
repo config:

```elixir
# migration
create index(:articles, [:title, :body], using: :fts,
         options: "weights = 'title=2.0,body=1.0'")

# queries
import Ecto.Adapters.Sediment.FTS.Query

from a in Article,
  where: fts_match([a.title, a.body], ^term),
  select: {a.id, fts_highlight(a.title, "<b>", "</b>", ^term)}

# ranked results, best first
Ecto.Adapters.Sediment.FTS.search(Repo, Article, [:title, :body], term, limit: 10)
#=> [{%Article{}, 1.37}, ...]
```

Turso only computes `fts_score` through the index when it shares its query
expression with `fts_match`, which an Ecto query with a pinned term can't
express (each `^term` is a separate parameter), so use
`Ecto.Adapters.Sediment.FTS.search/5` for ranking. See
`Ecto.Adapters.Sediment.FTS`.

### Concurrent transactions

In MVCC journal mode Turso supports `BEGIN CONCURRENT`, where write
transactions only conflict when they touch the same rows:

```elixir
config :my_app, MyApp.Repo,
  database: "path/to/my/database.db",
  journal_mode: :mvcc,
  default_transaction_mode: :concurrent   # or Repo.transaction(fun, mode: :concurrent)
```

Choose `:mvcc` when the database is created. An existing `:wal` database
with `AUTOINCREMENT` tables (Ecto's default primary keys) can't be switched to
it: turso_core 0.8.1 would then reuse ids and silently overwrite existing rows,
so the repo refuses to connect (`"refusing to switch to MVCC: ..."`) and leaves
the database untouched. To move such a database to MVCC, copy its data into a
new MVCC database.

The loser of a write-write conflict gets a `Sediment.Error` with the message
`"Write-write conflict"` and is rolled back; a commit that can't get its turn
fails with `"Database busy"`, and a transaction that overlaps another
connection's DDL (a migration) can fail with `"Database schema changed"`. All
three are safe to retry, since nothing of the transaction was written:

```elixir
def transaction_with_retry(fun, attempts \\ 10) do
  MyApp.Repo.transaction(fun)
rescue
  error in Sediment.Error ->
    if attempts > 1 and error.message =~ ~r/^(Write-write conflict|Database busy|Database schema changed)/ do
      transaction_with_retry(fun, attempts - 1)
    else
      reraise error, __STACKTRACE__
    end
end
```

Run the whole read-modify-write inside `fun`, so a retry reads fresh values.

Ecto runs each migration in a transaction. Turso doesn't allow DDL inside
`BEGIN CONCURRENT`, so when the default mode is `:concurrent` and a
transaction's first statement is DDL (as in a normal migration), sediment
begins it as `BEGIN IMMEDIATE` instead. Migrations therefore work unchanged and
stay atomic. The exception is a migration that writes data *before* its first
DDL statement (e.g. `repo().insert_all/2` at the top of `up/0`; remember that
`create`/`alter`/`execute` are queued until the end of the migration). It fails
with `DDL statements require an exclusive transaction` and is rolled back. Run
such migrations with another mode:

```elixir
Ecto.Migrator.with_repo(MyApp.Repo, &Ecto.Migrator.run(&1, :up, all: true),
  default_transaction_mode: :immediate)
```

or put the DDL first and call `flush()` before the data changes. A transaction
started explicitly with `mode: :concurrent` always uses `BEGIN CONCURRENT`.

Two more things to know in MVCC mode: prefer integer primary keys
(`migration_primary_key: [type: :integer]`, see "Differences" below), and
avoid running migrations while concurrent writers are active: turso_core can
panic in that situation. sediment contains the panic (the statement fails
with `"internal turso error: ..."` and that pool connection is replaced), but
the migration or write fails.

### Encryption

```elixir
config :my_app, MyApp.Repo,
  database: "path/to/my/database.db",
  encryption: [cipher: "aegis256", key: "<64 hex characters>"]
```

### S3-backed databases

With `:s3`, an S3 bucket/prefix is the durable state of record and the local
file is a working copy, restored from S3 when the repo starts. The
[S3 guide](guides/s3.md) covers production configuration, releases, deploys
with the single-writer lease, errors and restores.

```elixir
config :my_app, MyApp.Repo,
  database: "/var/lib/my_app/app.db",
  encryption: [cipher: "aegis256", key: System.fetch_env!("DATABASE_ENCRYPTION_KEY")],
  s3: [
    bucket: "my-bucket",
    prefix: "prod/app",
    region: "eu-central-1",
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")
    # endpoint: "http://127.0.0.1:8333" for S3-compatible servers
  ]
```

* Durability is asynchronous by default (`durability: :async`): commits
  return once they are committed locally and reach S3 in the background a
  moment later, so a crash can lose the last ones, but a restore is always a
  consistent prefix. `:max_lag_ms` (1 s by default) is a backpressure
  threshold, not a bound on the loss: new commits wait once the oldest
  un-uploaded one is that old, and a crash also loses the upload in flight
  (and up to `:upload_interval_ms` of commits, if set). `sync: true` on
  any `Repo` function (e.g. `Repo.transaction(fun, sync: true)`) waits for a
  commit, `Ecto.Adapters.Sediment.s3_flush/2` for everything so far, and
  `durability: :sync` makes every commit wait. See the S3 guide's
  "Durability" section.
* The journal mode defaults to `:mvcc` (required for S3) and `busy_timeout` to 15 s (with `durability: :sync`, commits hold the write lock while they upload).
* One writer at a time, enforced with a lease in the bucket. See
  `Sediment.S3` for lease, checkpoint and snapshot options.
* `mix ecto.create` / `storage_up/1` restores an existing database from S3 or
  creates a new one. `storage_status/1` and `storage_down/1` (`mix ecto.drop`)
  only look at the local working copy: **dropping does not delete the data
  in S3**.
* S3 databases are encrypted by default: a repo with `:s3` needs `:encryption`
  with a key (`openssl rand -hex 32` generates one), or `encryption: false` to
  store the database unencrypted; with neither it refuses to connect. The data
  in the bucket is encrypted at rest too, and restores need the same key.
  In-memory databases can't be S3-backed.
* Read-only replicas: a repo configured with `s3: [mode: :replica, ...]`
  restores the current state without taking the writer lease and never
  writes to S3, so any number of them can run next to the writer (use a
  different `database` path). Call `Ecto.Adapters.Sediment.s3_refresh(MyApp.ReplicaRepo)`
  (for example on a timer) to catch up with the writer.
  `Ecto.Adapters.Sediment.s3_info/1` reports the S3 state of a writer or replica.
* `Ecto.Adapters.Sediment.checkpoint/2` uploads a snapshot to S3 (incremental:
  only the changed segments) and starts a new log epoch, keeping restores fast.
  `mix ecto.sediment.checkpoint -r MyApp.Repo` does the same but starts the repo
  itself, so only while the application is stopped; on a running node call
  `checkpoint/2` (e.g. via `bin/my_app rpc`).
* Point-in-time restore: with `retain_epochs: n` in the `:s3` options, earlier
  epochs are kept, and `mix ecto.sediment.s3.restore -r MyApp.Repo -o copy.db
  --at 2026-09-29T21:00:00Z` (or `Ecto.Adapters.Sediment.s3_restore/3`) restores
  the state as of that moment into a standalone file. It only reads S3, so it
  is safe while the app runs; without `--at` it restores the latest state.
* Group commit (`group_commit: true` in the `:s3` options) uploads concurrently
  committed transactions as one object; see `Sediment.S3`.
* `mix ecto.dump`/`ecto.load` open their own connection, which needs the S3
  writer lease, so run them while the application isn't running.

A runnable walkthrough (write, `kill -9`, wipe the local copy, restore) is in
`examples/s3_demo` (see its README).

## Oban

Oban works on ecto_sediment with `Oban.Engines.Lite`, the engine for SQLite.
It needs Oban 2.24.0 or later: Oban 2.23 fails to start with an adapter it
doesn't know (it calls `repo().config()` at boot) whenever `:testing` isn't
`:disabled`.
Oban recognizes adapters by module name, so tell it which migrations to use:

```elixir
config :my_app, MyApp.Repo,
  database: "path/to/my/database.db",
  migrator: Oban.Migrations.SQLite

config :my_app, Oban,
  repo: MyApp.Repo,
  engine: Oban.Engines.Lite,
  queues: [default: 10]
```

and add a migration that calls `Oban.Migration.up()` / `Oban.Migration.down()`
as usual (`mix oban.install` doesn't recognize the adapter; write the config
and migration by hand).

`test/ecto/integration/oban_test.exs` runs job insertion, execution, retries
with backoff, discarding after `max_attempts`, scheduled jobs, unique jobs,
cancellation, the Pruner plugin and two Oban instances draining the same
queue (every job runs exactly once) in WAL, MVCC with `BEGIN CONCURRENT`, and
S3 mode. With an S3-backed repo every job state change is a commit; with the
default async durability those don't wait for S3, so job throughput is about
that of a local database. With `durability: :sync` each one waits for an S3
upload: expect tens of jobs per second per node (see the S3 guide).

## Type Extensions

Type extensions allow custom data types to be stored and retrieved from a
Turso database.

This is done by implementing a module with the `Ecto.Adapters.Sediment.TypeExtension`
behaviour which maps types to encoder and decoder functions. Type extensions are
activated by adding them, as a list of modules under the `type_extensions` key,
to both the `sediment` configuration (which encodes query parameters) and
the `ecto_sediment` configuration:

```elixir
config :sediment,
  type_extensions: [MyApp.TypeExtension]

config :ecto_sediment,
  type_extensions: [MyApp.TypeExtension]
```

Extensions are asked in order and the first one that doesn't return `nil`
wins. Loader functions are also called for `NULL` values, so they must accept
`nil`.

## ecto_sqlite3 parity

Every `Ecto.Adapters.SQLite3` option and feature, and its status in
`Ecto.Adapters.Sediment`. `test/ecto/integration/options_test.exs` sets every repo option.

### Repo options

| Option | Status |
| ------ | ------ |
| `:database` (incl. `:memory` / `":memory:"`) | Same |
| `:pool_size` | Same (default 5) |
| `:default_transaction_mode` | Same, plus `:concurrent` (`BEGIN CONCURRENT`, MVCC only) |
| `:journal_mode` | `:wal` (default) as in ecto_sqlite3; `:mvcc` added (for new databases: an existing database with `AUTOINCREMENT` tables can't switch to it, see "Concurrent transactions"); `:delete`, `:truncate`, `:persist`, `:memory`, `:off` accepted but have no effect |
| `:temp_store` | Same (default `:memory`) |
| `:synchronous` | Same (default `:normal`) |
| `:foreign_keys` | Same (default `:on`) |
| `:cache_size` | Same (default `-64000`) |
| `:cache_spill` | Same |
| `:busy_timeout` | Same (default `2000`; `15000` for S3 repos) |
| `:auto_vacuum` | `:none` same; `:full`/`:incremental` need `experimental: [:autovacuum]` |
| `:case_sensitive_like` | Accepted, no effect (`LIKE` is ASCII case-insensitive) |
| `:locking_mode` | Accepted, not applied (Turso locks the file per process) |
| `:secure_delete` | Accepted, no effect |
| `:wal_auto_check_point` | Accepted, no effect |
| `:load_extensions` | Not supported: the repo fails to connect (Turso can't load SQLite extensions) |
| `:key` (SQLCipher) | Not supported: use `:encryption` (which also works for S3-backed repos) |
| `:binary_id_type`, `:uuid_type`, `:map_type`, `:array_type`, `:datetime_type` | Same, under `config :ecto_sediment` (JSONB works for `:binary` map/array types) |
| `:type_extensions`, `:json_library` app config | Same, under `config :ecto_sediment` |
| New: `:mvcc_checkpoint_threshold` | Defaults to 256 KiB for MVCC repos without `:s3` (turso_core's ~4 MB default slows MVCC commits down, see [bench/RESULTS.md](bench/RESULTS.md)); `nil` restores Turso's default |
| New: `:encryption`, `:s3`, `:experimental`, `:custom_pragmas` | Turso extensions, see above and `Sediment.Connection.connect/1` |

### Features

| Feature | Status |
| ------- | ------ |
| SQL generation (queries, `update_all`, `delete_all`, CTEs, windows, unions, `values/2`, JSON paths) | Same SQL, same unit tests |
| Migrations (tables, indexes, column adds/renames, check constraints on columns) | Same; `ALTER COLUMN`, `ALTER TABLE ADD/DROP CONSTRAINT`, table prefixes unsupported as in ecto_sqlite3. New: `using: :fts` indexes |
| Upserts (`on_conflict`, `conflict_target`) | Same, except `on_conflict: :replace_all` including the primary key fails (Turso engine bug, see "Differences from ecto_sqlite3" below) |
| Constraint errors → changeset errors | Same (unique, check; foreign keys without a name) |
| Transactions, savepoints, `Repo.transact/2`, `Repo.stream/2` | Same |
| `Ecto.Adapters.SQL.Sandbox` | Same (no async tests, as in ecto_sqlite3), verified in WAL, MVCC and S3 modes |
| `storage_up/1`, `storage_down/1`, `storage_status/1` | Same; `storage_down/1` also removes `-tshm` and `.db-log`; S3 semantics documented above |
| `structure_dump/2`, `structure_load/2`, `dump_cmd/3` | Same results without the `sqlite3` executable; `dump_cmd/3` supports SQL and `.schema` only |
| Type extensions (`Ecto.Adapters.Sediment.TypeExtension`) | Same |
| `DELETE` with joins, row locks (`lock:`) | Not supported, as in ecto_sqlite3 |
| `LIKE` on `BLOB` columns | Different: Turso matches them |
| Views | Same; `INSTEAD OF` triggers on views are unsupported, materialized views need `experimental: [:views]` |
| ecto/ecto_sql integration suites | Run in WAL, MVCC, MVCC + `:concurrent`, encrypted, S3, S3 + group commit and encrypted S3 modes; the same exclusions as ecto_sqlite3 minus six tests Turso passes, plus two for the `replace_all` engine bug |

## Differences from ecto_sqlite3

* **No `sqlite3` executable needed.** `structure_dump/2`, `structure_load/2`
  and `dump_cmd/3` run in-process through the driver. `dump_cmd/3` accepts
  SQL statements (rows are printed `|`-separated, like the `sqlite3` CLI's
  default list mode) and the `.schema` command; other dot-commands return an
  error.
* **Schema SQL is normalized.** Turso stores a re-rendered `CREATE TABLE`
  statement in `sqlite_schema` rather than the original text (e.g.
  `F32_BLOB (3)`), so `mix ecto.dump` output can differ in whitespace from
  what the migration generated, and `pragma_table_info` reports declared
  types without their size (`F32_BLOB`).
* **Internal tables.** `sqlite_master` also lists Turso's
  `__turso_internal_*` tables (one per `AUTOINCREMENT` table, and one more
  in MVCC mode); skip them, like `sqlite_*`, when listing tables.
* **Error messages** raised by the adapter for unsupported features say
  "Turso" instead of "SQLite3", e.g. `"Turso does not support table prefixes"`.
* **Multi-column unique violations.** Turso reports them as
  `UNIQUE constraint failed: users.(email, name)`; the adapter maps this to
  the same `users_email_name_index` constraint name as ecto_sqlite3 does.
* **`storage_down/1`** also removes Turso's `-tshm` and MVCC `.db-log` files.
  Turso names the MVCC log after the file's stem (`app.db` and
  `app.sqlite` would both use `app.db-log`), so keep one database per stem
  in a directory.
* **SQLite pragmas Turso doesn't implement** (`:case_sensitive_like`,
  `:locking_mode`, `:secure_delete`, `:wal_auto_check_point`) are accepted and
  ignored. `:load_extensions` and `:key` (SQLCipher) are not supported; use
  `:encryption` instead.
* **`LIKE` matches `BLOB` columns** (ecto_sqlite3's SQLite is built with
  `SQLITE_LIKE_DOESNT_MATCH_BLOBS`). The corresponding ecto integration tests
  (`:like_match_blob`), as well as `:right_join`, `:concat` and the
  `selected_as` tests, pass on Turso and are enabled.
* **Up to 250,000 parameters per statement** (SQLite: 32,766), so
  `Repo.insert_all/3` takes bigger batches; beyond that it fails with
  `variable number must be between ?1 and ?250000` and inserts nothing.
* **`:time_usec` fields work** (ecto_sqlite3 has no loader for them and
  fails to read them back). Times keep their microseconds.
* **Decimals** behave as in ecto_sqlite3: a `:decimal` column is created as
  `DECIMAL`, which has NUMERIC affinity, so SQLite stores a decimal as a REAL
  when it looks like one and only about 15 significant digits survive
  (`12345678901234567890.123456789` comes back rounded). For exact decimals
  (money, say) use a text column with a `:decimal` field: `add :amount, :text`.
* **`AUTOINCREMENT` in MVCC mode.** Ecto's default `:bigserial` primary keys
  become `INTEGER PRIMARY KEY AUTOINCREMENT` (as in ecto_sqlite3), and in MVCC
  mode (including S3 repos) turso_core handles them slowly: single-row inserts
  are 2x or more slower than with a plain `INTEGER PRIMARY KEY`, and inserts
  get slower as a transaction grows (5,000 rows in one transaction: 2.7 s
  instead of 0.12 s). With `default_transaction_mode: :concurrent`,
  concurrent inserts into one such table also conflict with each other on
  the id sequence (4 writers: about 9% of transactions failed with
  `"Write-write conflict"`, none with integer keys), and on S3 every insert
  uploads a log frame of its own. Use `migration_primary_key: [type: :integer]`
  for MVCC repos; see the getting started guide.
* **Schema changes under a write transaction (MVCC).** turso re-prepares a
  statement whose schema changed at most twice inside a write transaction,
  so a transaction that overlaps a migration running on another connection
  can fail with `"Database schema changed"`: retry it (see the recipe in
  "Concurrent transactions"), or migrate while nothing else writes.
* **Known Turso engine issues** (turso_core 0.8.1), excluded from the
  integration suite with a comment:
  * `on_conflict: :replace_all` fails with `datatype mismatch`: in an upsert,
    `excluded.id` for an `INTEGER PRIMARY KEY` column is `NULL` in Turso
    instead of the would-be new rowid. Use `{:replace_all_except, [:id]}` or
    an explicit `{:replace, fields}`.
  * `full_join` fails with `FULL OUTER JOIN requires an equality condition`
    when the joined table's column in the `on:` condition is indexed (a
    primary key, say). Prefix that column with a unary plus so Turso doesn't
    use the index: `on: fragment("+?", p.id) == c.parent_id`. (Unary plus
    also drops the column's affinity and collation.)
  * Dropping a column that has its own `REFERENCES` fails with
    `unknown column "parent_id" in foreign key definition`, so `remove`
    of such a column, and rolling back `add :parent_id, references(...)`,
    fail. Write the migration's `down` as a table rebuild instead, with
    foreign keys off on one connection; see "Behaviour to check in your
    application" in the migrating guide.
* **Other Turso SQL gaps** affect raw SQL rather than the adapter. In
  turso_core 0.8.1, `INSTEAD OF` triggers (triggers on views) are not
  supported. Recursive CTEs, all window functions including custom frames,
  aggregate `FILTER`, and JSONB work. See Turso's
  [COMPAT.md](https://github.com/tursodatabase/turso/blob/main/COMPAT.md) for
  the full list, but check against 0.8.1: it describes a newer version.

## Benchmarks

`bench/` compares ecto_sediment (WAL, MVCC, MVCC+S3) with ecto_sqlite3; see
[bench/RESULTS.md](bench/RESULTS.md). Reads (point lookups and
bulk loads) and multi-statement transactions are faster than ecto_sqlite3,
single-row inserts in WAL mode somewhat slower; MVCC with integer primary keys
is the fastest mode for writes, and MVCC benefits from a lower checkpoint
threshold, which ecto_sediment therefore uses by default
(`mvcc_checkpoint_threshold: 262_144`). S3 repos with the default async
durability write at about the speed of local MVCC (0.13 ms per insert against
a local SeaweedFS); `durability: :sync` adds an S3 round trip to every commit.

## Running Tests

```sh
mix test   # unit and adapter integration tests (S3 ones need SeaweedFS on :8333)
mix ci     # everything CI runs: the ecto/ecto_sql suites in all modes, linters
```

[CONTRIBUTING.md](https://github.com/flmngco/ecto_sediment/blob/main/CONTRIBUTING.md) describes the setup (Sediment checked out
next to this repository, SeaweedFS 4.48 for the S3 tests), the test tags and
the other S3 servers.

## Publishing to Hex

Releases are published by CI from a GitHub release; see
[RELEASING.md](https://github.com/flmngco/ecto_sediment/blob/main/RELEASING.md).

## Acknowledgements

* Built on the [Turso](https://github.com/tursodatabase/turso) database engine
  (`turso_core`, MIT), through [Sediment](https://github.com/flmngco/sediment).
* Derived from [ecto_sqlite3](https://github.com/elixir-sqlite/ecto_sqlite3) by
  Matthew A. Johnston and contributors (MIT): the adapter, its options, the
  generated SQL and its test suites are ported from it. Sediment's API follows
  [exqlite](https://github.com/elixir-sqlite/exqlite) by the same author.
* Sediment's native code uses [Rustler](https://github.com/rusterlium/rustler).

## License

MIT, see [LICENSE](https://github.com/flmngco/ecto_sediment/blob/main/LICENSE) (which keeps ecto_sqlite3's copyright notice).
