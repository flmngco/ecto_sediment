# Changelog

## 0.2.0-beta.1 (2026-10-24)

0.2 breaks 0.1, with sediment 0.2: the S3 manifest is version 4, the repo's
`:encryption` is a key ring, and options of functions taking keys must be
keyword lists. Data written by 0.1 is not migrated (see sediment's
CHANGELOG). The Hex dependency is `{:sediment, "~> 0.2.0-beta.1"}`.

* Requires sediment with key rotation (manifest version 4; see its
  CHANGELOG, a breaking change for S3 prefixes written by older versions).
  The repo's `:encryption` may be a key ring (`keys:`, `key_for:`), passed
  through to every connection, to `s3_restore`, `s3_import` and the export
  task unchanged.
* Key rotation for repos (see "Rotating keys" in the S3 guide):
  * `s3_rekey/2`, `s3_release_key/3` and `s3_key_census/1` take a repo
    module or a dynamic repo's configuration (`:database`, `:s3`,
    `:encryption`); the results are sediment's. A rekey or release of a
    repo running in this VM (or of its database file or S3 location) is
    refused with a message naming the repo; a repo is never stopped.
  * `s3_rekey_many/2`, `s3_release_key_many/3` and `s3_key_census_many/2`
    run them over repos and `{id, config}` tenant configurations, a few at
    a time, with sediment's retries and callbacks (`around:` closes and
    reopens each tenant, so each pauses only for its own rekey). The
    callbacks get each configuration with its `:encryption` hidden (still
    usable to start the repo); a reopen failing after the rekey fails the
    tenant with `{:around_failed, reason, result}`, a linked process
    exiting with `{:linked_exit, result}`.
  * `mix ecto.sediment.s3.rekey`, `mix ecto.sediment.s3.release_key KEY_ID`
    and `mix ecto.sediment.s3.key_census` for named repos (`-r`,
    repeatable): one line per repo, a non-zero exit on any failure. A repo
    whose S3 location holds no database prints `no database at
    <bucket>/<prefix>: wrong bucket or prefix?` and fails the task: a
    misaddressed repo must never read as done, nor its key as removable.
  * The running-repo check works without `:ecto` started (a release's
    `eval`); the tasks start `:ecto` so that it sees the repos.
* Ecto's own configuration errors (`log: :verbose`, a driver missing) keep
  their message through sediment's boundary, under its net.
* No key shows in an error from a repo configuration or options of the
  wrong shape: every documented function of the adapter (`s3_*`,
  `export_sqlite`, `checkpoint`, `dump_cmd`, and so their Mix tasks), the
  configuration callbacks (`init/1`, which a repo's start runs its
  configuration through, and `ensure_all_started/2`), the storage and
  structure callbacks (`structure_dump`, `structure_load`) and the pool's
  start run inside sediment's boundary, with its net on every error (see
  its CHANGELOG). A pool option of the wrong type (`pool: <a ring>`,
  `pool_size: <a key>`) is refused with a fixed message, where Ecto or the
  pool's process failed with the value in the error or crash report. Their options must be a keyword list; `repo_or_s3` of
  another type is refused with a fixed message instead of a
  `FunctionClauseError`. `storage_down/1` and `storage_status/1` without a
  `:database` raise a fixed message instead of a `KeyError` (which showed
  the whole configuration). `s3_restore` returns an error instead of
  raising when it can't create the target's directory.
* In the SQL sandbox, a transaction begun after the database rolled the
  test's transaction back (a write-write conflict, `ON CONFLICT ROLLBACK`)
  raises `Sediment.Error` ("the transaction was rolled back by the
  database ...") and keeps the connection, where it crashed it with a
  `CaseClauseError`.
* The S3 guide says how to import a file restored from before a key
  rotation (`source_encryption:` with that epoch's key).

## 0.1.0-beta.4 (2026-10-08)

* Requires sediment 0.1.0-beta.5: warm reopen of S3 databases, and a fix
  for a rare empty reopen after a pool stop.

### S3

* S3 repos default to `queue_interval: 15_000`. A connection restores the
  database while it connects, and with DBConnection's 2 s default the
  queries made meanwhile (migrations right after a start) were dropped from
  the pool's queue after about 4 s. They now wait until their `:timeout`.

## 0.1.0-beta.3 (2026-10-07)

* Requires sediment 0.1.0-beta.4, which fixes lost query cancels (a pool
  connection could stay stuck after a client timeout under load).

### S3

* `s3_snapshot/1` checkpoints an S3-backed repo and uploads a snapshot now
  (`Sediment.S3.snapshot/1`); it takes a repo module or a repo pid.

## 0.1.0-beta.2 (2026-10-05)

### S3

* `s3_destroy/2` deletes a repo's S3 database (`Sediment.S3.destroy/2`),
  and `s3_exists?/1` tells whether a location holds one; both take a repo
  module or its `:s3` options. `must_exist: true` in the `:s3` options makes
  a repo refuse to start with a new, empty database. The multi-tenant guide
  uses them for deleting tenants and for tenants that must exist.

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
