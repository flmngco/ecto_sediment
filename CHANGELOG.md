# Changelog

## Unreleased

### Fixed

* `storage_down/1` removed the `.db-log` named after the file without its
  extension even when that log belonged to another database file
  (`app.sqlite` next to an MVCC `app.db`). It now removes the log only for
  an MVCC database, whose log Sediment keeps its own.

### Docs

* Migrating guide: the table rebuild that replaces dropping a column with
  its own `REFERENCES` now runs with foreign keys off on one connection.
  Run in the migration's transaction, `DROP TABLE` failed when other rows
  referenced the table, or ran their `ON DELETE` actions (deleting rows with
  `on_delete: :delete_all`).
* Turso's `__turso_internal_*` tables in `sqlite_master` are documented.

## 0.1.0-beta.1 (2026-10-04)

First version: a port of ecto_sqlite3 0.25 to Turso (turso_core 0.8.1) via
sediment.

### Core API (ecto_sqlite3 parity)

* `Ecto.Adapters.Sediment`, `.Connection`, `.Codec`, `.DataType` and
  `.TypeExtension`, with the same options, generated SQL, types and
  migrations as `Ecto.Adapters.SQLite3`. Differences are listed in the README
  ("ecto_sqlite3 parity", "Differences from ecto_sqlite3").
* `structure_dump/2`, `structure_load/2` and `dump_cmd/3` run in-process;
  no `sqlite3` executable is needed.
* Turso's multi-column `UNIQUE` violation messages map to constraint names.
* `:time_usec` fields load and dump (ecto_sqlite3 can't read them back).

### Turso extensions

* MVCC and `BEGIN CONCURRENT` (`default_transaction_mode: :concurrent`,
  `mode: :concurrent`); migrations keep working under the concurrent default.
* Encryption (`encryption: [cipher:, key:]`), also for S3-backed repos (the
  data in the bucket is encrypted too; restores use the repo's key).
* Vectors: `Ecto.Adapters.Sediment.Vector` and `Vector64` types, `:vector32` /
  `:vector64` migration types, `Ecto.Adapters.Sediment.Vector.Query` distance
  macros.
* Full-text search: `using: :fts` indexes and `Ecto.Adapters.Sediment.FTS`.

### S3 durability

* S3-backed repos (`s3: [...]`), asynchronous by default
  (`durability: :async`): a commit returns once it is in the local log and is
  uploaded in the background; a crash can lose the last commits, and a
  restore is always a prefix of them.
* Encrypted by default: an S3-backed repo needs `:encryption` with a key, or
  an explicit `encryption: false`. The installer's `--s3` reads the key from
  `DATABASE_ENCRYPTION_KEY`.
* `sync: true` on any repo function waits until that commit is durable;
  `s3_flush/2` waits for everything committed so far; `durability: :sync`
  makes every commit wait.
* A loss of acknowledged commits is reported (`s3_flush/2` and `sync: true`
  fail, `s3_info/1` names the range) until `s3_acknowledge_loss/1`.
* Pending uploads are flushed when the repo stops and when a script or Mix
  task exits.
* MVCC and a 15 s `busy_timeout` by default; nil-valued `:s3` options are
  ignored.
* `checkpoint/2` and `mix ecto.sediment.checkpoint`; point-in-time restore with
  `s3_restore/3` and `mix ecto.sediment.s3.restore` (which never replace an
  existing file); read-only replica repos with `s3_refresh/1`; `s3_info/1`.
* `s3_import/3` (`mix ecto.sediment.s3.import`) moves an existing database
  file into S3; `export_sqlite/3` (`mix ecto.sediment.export_sqlite`) writes
  a plain SQLite copy. Like `s3_restore/3`, both take a repo module or its
  `:s3` options (for dynamic repos).

### Robustness

* The ecto and ecto_sql integration suites run in WAL, MVCC,
  MVCC + `default_transaction_mode: :concurrent`, encrypted, S3,
  S3 + group commit and encrypted S3 modes, on
  Elixir 1.18 to 1.20.
* S3 disaster-recovery, outage (docker-paused S3), latency, multi-tenant and
  crash-torture test suites.

### Performance

* MVCC repos without `:s3` default to a 256 KiB checkpoint threshold
  (`mvcc_checkpoint_threshold`); turso_core's ~4 MB default slows MVCC
  commits down.
* `bench/`: benchmarks against ecto_sqlite3 (`bench/RESULTS.md`).

### Integrations

* Oban (2.24.0 or later): `Oban.Engines.Lite` works (set `migrator: Oban.Migrations.SQLite` in
  the repo config); tested in WAL, MVCC with `BEGIN CONCURRENT` and S3 modes.
* Igniter installer: `mix igniter.install ecto_sediment` / `mix ecto_sediment.install`
  sets up a repo like Phoenix does for ecto_sqlite3, optionally S3-backed.

### Docs and tooling

* Guides: getting started, S3-backed repos (configuration, releases, deploys
  with the single-writer lease, errors, restores, performance), multi-tenant
  apps (a repo per tenant, started on demand, with idle shutdown), migrating
  from ecto_sqlite3.
* `examples/s3_demo`: a runnable write / `kill -9` / wipe / restore
  walkthrough, also as a release.
* Hex packaging: `SEDIMENT_HEX=1 mix hex.build` (requires sediment on Hex).
  sediment's NIF comes precompiled for the common targets, so no Rust
  toolchain is needed to use ecto_sediment.
