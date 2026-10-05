# Migrating from ecto_sqlite3

`Ecto.Adapters.Sediment` is a port of `Ecto.Adapters.SQLite3`: the options,
generated SQL, column types and migrations are the same, so most
applications switch with a few lines of configuration.

## Steps

1. Replace the dependency:

   ```elixir
   # {:ecto_sqlite3, "~> 0.17"},
   {:ecto_sediment, "~> 0.1"}
   ```

   sediment, the driver, comes with it, with a precompiled NIF for the
   common targets; others need a Rust toolchain (see the README's
   installation section).

2. Change the adapter:

   ```elixir
   use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Sediment
   ```

3. Move application-level settings from `config :ecto_sqlite3` to
   `config :ecto_sediment`: `:binary_id_type`, `:uuid_type`, `:map_type`,
   `:array_type`, `:datetime_type`, `:type_extensions` and `:json_library`.
   Keep their values; data is stored the same way. Driver-level type
   extensions move from `config :exqlite, type_extensions: ...` to
   `config :sediment, type_extensions: ...` (see "Type Extensions" in the
   README: a type extension is configured under both keys).

4. Rename type extension modules' behaviour from
   `Ecto.Adapters.SQLite3.TypeExtension` to `Ecto.Adapters.Sediment.TypeExtension`
   (same callbacks), and `Exqlite.TypeExtension` to `Sediment.TypeExtension`.

5. Rename the driver modules your own code names: errors raised by the
   driver are `Sediment.Error` instead of `Exqlite.Error`, so change
   `rescue Exqlite.Error` and `assert_raise Exqlite.Error, ...` (for
   example around a trigger's `RAISE(ABORT, ...)`); a constraint violation
   still becomes a changeset error. Raw database handles move from
   `Exqlite.Sqlite3` to `Sediment.Engine` (same functions: `open/2`,
   `execute/2`, `prepare/2`, `fetch_all/2`, `release/2`, `close/1`, ...),
   and `Exqlite.Basic` to `Sediment.Basic`.

6. Check the repo options against the list below.

Existing database files open directly: Turso reads the SQLite file format.

> #### Existing data and `:s3` {: .warning}
>
> Adding the `:s3` option doesn't upload an existing database. With an empty
> prefix the repo refuses to start over a database file that has tables
> (`"s3 config: ... refusing to replace the local file ..."`) and leaves it
> alone. With a prefix that already holds a database, starting the repo
> replaces the local file with the S3 copy. To move existing data to S3,
> import it, see "Moving an existing database to S3" below.

## Repo options that behave differently

| Option | In ecto_sediment |
| ------ | ------------- |
| `:journal_mode` | `:wal` (default) and the Turso-only `:mvcc`; keep `:wal` for a migrated database: one with `AUTOINCREMENT` tables can't be switched to `:mvcc` (see "What you gain"). `:delete`, `:truncate`, `:persist`, `:memory` and `:off` are accepted but have no effect. |
| `:case_sensitive_like`, `:locking_mode`, `:secure_delete`, `:wal_auto_check_point` | Accepted, no effect. `LIKE` is case-insensitive for ASCII. |
| `:auto_vacuum` | `:full` and `:incremental` need `experimental: [:autovacuum]`. |
| `:load_extensions` | Not supported: the repo fails to connect. |
| `:key` (SQLCipher) | Not supported: use `encryption: [cipher: "aegis256", key: "<64 hex chars>"]`. An existing SQLCipher database can't be opened; export and re-import the data. |

Everything else (`:database`, `:pool_size`, `:default_transaction_mode`,
`:temp_store`, `:synchronous`, `:foreign_keys`, `:cache_size`,
`:cache_spill`, `:busy_timeout`) works the same.

## Behaviour to check in your application

* `mix ecto.dump` / `mix ecto.load` / `dump_cmd/3` don't need the `sqlite3`
  executable any more. `dump_cmd/3` accepts SQL statements and `.schema`
  only. Dumped `CREATE TABLE` statements may differ in whitespace, because
  Turso stores a re-rendered form.
* `on_conflict: :replace_all` fails with `datatype mismatch` when the
  replaced fields include an `INTEGER PRIMARY KEY` (a turso_core 0.8.1 bug).
  Use `{:replace_all_except, [:id]}` or `{:replace, fields}`.
* `LIKE` also matches `BLOB` columns.
* Triggers on views (`INSTEAD OF`) are not supported.
* Dropping a column that has its own `REFERENCES` fails with
  `unknown column "author_id" in foreign key definition` (a turso_core 0.8.1
  bug). That breaks `remove :author_id` and the rollback of
  `add :author_id, references(:authors)`. Give such a migration an explicit
  `down` that rebuilds the table without the column, then recreate its
  indexes and triggers.

  The rebuild drops the old table, and with foreign keys on, `DROP TABLE`
  fails when other tables' rows reference it, or runs their `ON DELETE`
  actions (`on_delete: :delete_all` deletes those rows). So turn foreign keys
  off for the rebuild. `PRAGMA foreign_keys` has no effect inside a
  transaction and applies to one connection, so run the migration without
  its DDL transaction and do the rebuild on one checked-out connection, in a
  transaction of its own:

  ```elixir
  @disable_ddl_transaction true

  def up do
    alter table(:books) do
      add :author_id, references(:authors, on_delete: :nilify_all)
    end
  end

  def down do
    repo().checkout(fn ->
      repo().query!("PRAGMA foreign_keys = OFF")

      try do
        repo().transaction(fn ->
          create table(:books_new) do
            add :title, :string
          end

          execute "INSERT INTO books_new (id, title) SELECT id, title FROM books"
          drop table(:books)
          rename table(:books_new), to: table(:books)
          flush()
        end)
      after
        repo().query!("PRAGMA foreign_keys = ON")
      end
    end)
  end
  ```

  The `after` turns foreign keys back on before the connection returns to
  the pool. Keep the rebuilt table's columns and primary key as they were,
  so the rows that reference it still match (`PRAGMA foreign_key_check`
  lists any that don't).
* Turso keeps its own bookkeeping tables in `sqlite_master`, next to
  SQLite's `sqlite_*` ones: one `__turso_internal_seq_*` table per
  `AUTOINCREMENT` table and, in MVCC mode (S3 repos included),
  `__turso_internal_mvcc_meta`. Code that lists the tables (a backup check,
  a test that compares schemas or row counts) should skip names starting
  with `sqlite_` or `__turso_internal_`. Their contents are internal and
  can differ between a running writer and a restored copy of the same
  database.
* Error messages raised by the adapter for unsupported features say "Turso"
  instead of "SQLite3". Constraint errors map to changeset errors exactly as
  before.
* Performance differs by operation: reads and multi-statement transactions
  are faster than ecto_sqlite3, single-row inserts in WAL mode somewhat
  slower; see `bench/RESULTS.md`.

## Moving an existing database to S3

With the application stopped and `:s3` added to the repo's configuration
(with `:encryption`: a key, or `false`; S3 databases are encrypted by
default):

```console
$ mix ecto.sediment.s3.import -r MyApp.Repo
```

This copies the repo's database file (never writing to it) into a new MVCC
database, ids and AUTOINCREMENT sequences, indexes, views, triggers and
foreign keys included, and uploads it to the empty S3 prefix. Then start the
application as usual. It takes about 4 minutes per million rows (the app
is stopped meanwhile); WITHOUT ROWID and virtual (fts5) tables are refused.
See
[S3-backed repos](s3.md#importing-an-existing-database).

## Going back

`mix ecto.sediment.export_sqlite -r MyApp.Repo -o app-sqlite.db` exports the
repo's database (its file, or its S3 prefix) to a plain SQLite file; switch
the repo back to `Ecto.Adapters.SQLite3` with `database:` pointing at it.
AUTOINCREMENT ids continue where they were. Turso FTS indexes have to be left
out (`--drop-fts`), and vector columns become plain blobs; see sediment's
"Leaving Sediment" guide.

## What you gain

* `journal_mode: :mvcc` with `BEGIN CONCURRENT` for concurrent writers, for new
  databases. Don't switch a migrated SQLite database with `AUTOINCREMENT` tables
  to it: turso_core 0.8.1 would reuse ids and overwrite rows, so the repo
  refuses to connect (`"refusing to switch to MVCC: ..."`); copy the data into
  a new MVCC database instead.
* Encryption at rest without a custom SQLite build.
* [S3-backed repos](s3.md) with asynchronous durability (or synchronous, per
  commit or for all), crash recovery on any machine, read replicas and
  point-in-time restore.
* Vector columns and distance functions, and full-text search indexes.
