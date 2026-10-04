# Getting started

This guide sets up a new Ecto project on Turso. For moving an existing
ecto_sqlite3 project, see the [migration guide](migrating_from_ecto_sqlite3.md).

## Dependencies

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
(x86_64), so no Rust toolchain is needed. On other targets, or to build from
source anyway, set `SEDIMENT_BUILD=1`, install Rust 1.91 or later and add
`{:rustler, "~> 0.38", runtime: false}` to your dependencies; see sediment's
README.

With [Igniter](https://hexdocs.pm/igniter), `mix igniter.install
ecto_sediment` (add `--s3` for an S3-backed prod repo) does the
steps below for you: it creates the repo, adds it to the supervision tree and
writes the dev, test and runtime configuration.

## The repo

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Sediment
end
```

```elixir
# config/config.exs
config :my_app, ecto_repos: [MyApp.Repo]

# config/dev.exs
config :my_app, MyApp.Repo,
  database: Path.expand("../my_app_dev.db", __DIR__),
  pool_size: 5
```

Add the repo to your supervision tree, then create the database and run
migrations as usual:

```sh
mix ecto.create
mix ecto.gen.migration create_posts
mix ecto.migrate
```

Migrations use the same column types as ecto_sqlite3 (`:string` is `TEXT`,
`:boolean` is `INTEGER`, `:utc_datetime` is `TEXT`, and so on). Turso adds
`:vector32`/`:vector64` columns, see `Ecto.Adapters.Sediment.Vector`, and
full-text search indexes (`create index(:posts, [:title, :body], using: :fts)`).

## Choosing a journal mode

| `journal_mode` | Use it when |
| -------------- | ----------- |
| `:wal` (default) | You want the behaviour of ecto_sqlite3: one writer at a time, readers never block. The fastest option for reads; with the default `AUTOINCREMENT` primary keys also for writes. |
| `:mvcc` | You want several write transactions at once with `BEGIN CONCURRENT` (`default_transaction_mode: :concurrent` or `Repo.transaction(fun, mode: :concurrent)`), or you use S3 (which requires it). Transactions touching the same rows conflict and one of them is rolled back with `"Write-write conflict"`; retry it. |

See `bench/RESULTS.md` for measured differences.

Choose `:mvcc` when the database is created. An existing `:wal` database
with `AUTOINCREMENT` tables (Ecto's default primary keys) can't be switched to
it: turso_core 0.8.1 would then reuse ids and silently overwrite existing rows,
so the repo refuses to connect (`"refusing to switch to MVCC: ..."`) and leaves
the database untouched. To move such a database to MVCC, copy its data into a
new MVCC database.

### Primary keys in MVCC mode

Ecto migrations create `:bigserial` primary keys, which ecto_sqlite3 (and this
adapter) render as `INTEGER PRIMARY KEY AUTOINCREMENT`. In MVCC mode (and so
for S3 repos), turso_core 0.8.1 handles them slowly: single-row inserts are
2x or more slower than with a plain `INTEGER PRIMARY KEY`, and every insert
gets slower as the enclosing transaction grows (10 `insert_all/3` calls of 500
rows in one transaction took 2.7 s, against 0.12 s). For MVCC repos, use plain
integer primary keys:

```elixir
config :my_app, MyApp.Repo, migration_primary_key: [type: :integer]
```

With `BEGIN CONCURRENT`, concurrent inserts into an `AUTOINCREMENT` table
also conflict on the id sequence (a `"Write-write conflict"` for about one
transaction in ten at 4 writers); plain integer keys avoid that too.

The difference: without `AUTOINCREMENT`, the id of the most recently inserted
row can be reused after that row is deleted. WAL mode is not affected.

## Tests

Use `Ecto.Adapters.SQL.Sandbox` as with ecto_sqlite3:

```elixir
# config/test.exs
config :my_app, MyApp.Repo,
  database: Path.expand("../my_app_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
```

As with ecto_sqlite3, sandboxed tests can't use `async: true`: each test holds
a write transaction for its whole duration and only one runs at a time (a
second writer fails with `"Database busy"` after `busy_timeout`). This holds in
MVCC mode too, because sandbox transactions use a plain `BEGIN`. `allow/3`,
shared mode and `unboxed_run/2` work as usual.

For an S3-backed production repo, a plain local database in tests is usually
enough; test the S3 behaviour itself against a local S3 server such as
SeaweedFS.

## Background jobs

Oban (2.24.0 or later) works with `engine: Oban.Engines.Lite`; set `migrator: Oban.Migrations.SQLite`
in the repo config, since Oban recognizes adapters by module name. See the
README's Oban section.

## Next steps

* [S3-backed repos](s3.md): durable databases stored in S3.
* `Ecto.Adapters.Sediment`: every option, encryption, concurrent transactions.
* The README's "Differences from ecto_sqlite3" and parity table.
