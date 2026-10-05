defmodule Ecto.Adapters.Sediment do
  @moduledoc """
  Ecto adapter for Sediment, on the Turso database engine.

  It uses `Sediment` for communicating to the database.

  ## Options

  The adapter supports a superset of the options provided by the
  underlying `Sediment` driver.

  ### Provided options

    * `:database` - The path to the database. In memory is allowed. You can use
      `:memory` or `":memory:"` to designate that.
    * `:default_transaction_mode` - one of `:deferred` (default), `:immediate`,
      `:exclusive` or `:concurrent`. If a mode is not specified in a call to
      `Repo.transaction/2`, this will be the default transaction mode. See
      [concurrent transactions](#module-concurrent-transactions).
    * `:journal_mode` - `:wal` (default) or `:mvcc`. `:mvcc` enables `BEGIN CONCURRENT`
      and is required for S3-backed databases, where it is the default. SQLite's
      other journal modes are accepted by the driver and have no effect. Choose
      `:mvcc` when the database is created: an existing `:wal` database with
      `AUTOINCREMENT` tables (Ecto's default primary keys) can't be switched to it,
      since turso_core 0.8.1 would then reuse ids and overwrite existing rows. The
      repo refuses to connect instead (`"refusing to switch to MVCC: ..."`) and
      leaves the database untouched; copy the data into a new MVCC database.
    * `:mvcc_checkpoint_threshold` - bytes of MVCC logical log after which Turso
      checkpoints automatically. Defaults to `262_144` (256 KiB) for `journal_mode: :mvcc`
      repos without `:s3`; turso_core's own default (about 4 MB) lets commits slow down
      noticeably before the first checkpoint (see `bench/RESULTS.md`). Set it to `nil` to
      use Turso's default. S3-backed repos use the `:checkpoint_threshold` option of `:s3`.
    * `:temp_store` - Sets the storage used for temporary tables. Default is `:memory`.
      Allowed values are `:default`, `:file`, `:memory`.
    * `:synchronous` - Can be `:extra`, `:full`, `:normal`, or `:off`. Defaults to `:normal`.
    * `:foreign_keys` - Sets if foreign key checks should be enforced or not. Can be
      `:on` or `:off`. Default is `:on`.
    * `:cache_size` - Sets the cache size to be used for the connection. This is an odd
      setting as a positive value is the number of pages in memory to use and a negative
      value is the size in kilobytes to use. Default is `-64000`.
    * `:cache_spill` - `:on` (default) or `:off`.
    * `:auto_vacuum` - Defaults to `:none`. `:full` and `:incremental` require
      `experimental: [:autovacuum]`.
    * `:busy_timeout` - Sets the busy timeout in milliseconds for a connection.
      Default is `2000`.
    * `:pool_size` - the size of the connection pool. Defaults to `5`.
    * `:encryption` - `[cipher: "aegis256", key: "<hex key>"]` to open an encrypted
      database. S3-backed databases require it: pass a key, or `false` for an
      unencrypted S3 database. See [encryption](#module-encryption).
    * `:s3` - makes an S3 bucket the durable store of the database. See
      [S3-backed databases](#module-s3-backed-databases).
    * `:experimental` - list of experimental Turso features to enable, such as
      `:views`, `:generated_columns` or `:index_method`. See `Sediment.Engine.open/2`.
    * `:binary_id_type` - Defaults to `:string`. Determines how binary IDs are stored in
      the database and the type of `:binary_id` columns. See the
      [section on binary ID types](#module-binary-id-types) for more details.
    * `:uuid_type` - Defaults to `:string`. Determines the type of `:uuid` columns.
      Possible values and column types are the same as for
      [binary IDs](#module-binary-id-types).
    * `:map_type` - Defaults to `:string`. Determines the type of `:map` columns.
      Set to `:binary` to use the [JSONB](https://sqlite.org/jsonb.html)
      storage format.
    * `:array_type` - Defaults to `:string`. Determines the type of `:array` columns.
      Arrays are serialized using JSON. Set to `:binary` to use the
      [JSONB](https://sqlite.org/jsonb.html) storage format.
    * `:datetime_type` - Defaults to `:iso8601`. Determines how datetime fields are
      stored in the database. The allowed values are `:iso8601` and `:text_datetime`.
      `:iso8601` corresponds to a string of the form `YYYY-MM-DDThh:mm:ss` and
      `:text_datetime` corresponds to a string of the form `YYYY-MM-DD hh:mm:ss`

  The SQLite options `:case_sensitive_like`, `:locking_mode`, `:secure_delete` and
  `:wal_auto_check_point` are accepted for compatibility with ecto_sqlite3, but Turso
  does not implement them. `:load_extensions` and `:key` are not supported. See
  `Sediment.Connection.connect/1` for details.

  For more information about the options above, see [sqlite documentation][1]

  ### Differences between SQLite and Ecto SQLite defaults

  For the most part, the defaults we provide above match the defaults that SQLite usually
  ships with. However, SQLite has conservative defaults due to its need to be strictly
  backwards compatible, so some of them do not necessarily match "best practices". Below
  are the defaults we provide above that differ from the normal SQLite defaults, along
  with rationale.

    * `:journal_mode` - we use `:wal`, which handles concurrent access
      much better. SQLite usually defaults to `:delete`.
      See [SQLite documentation][2] for more info.
    * `:temp_store` - we use `:memory`, which increases performance a bit.
      SQLite usually defaults to `:file`.
    * `:foreign_keys` - we set it to `:on`, for better relational guarantees.
      This is also the default of the underlying `Sediment` driver.
      SQLite usually defaults to `:off` for backwards compat.
    * `:busy_timeout` - we set it to `2000`, to better enable concurrent access.
      This is also the default of `Sediment`. SQLite usually defaults to `0`.
    * `:cache_size` - we set it to `-64000`, to speed up access of data.
      SQLite usually defaults to `-2000`.

  These defaults can be overridden, as noted above.

  [1]: https://www.sqlite.org/pragma.html
  [2]: https://sqlite.org/wal.html

  ### Binary ID types

  The `:binary_id_type` configuration option allows configuring how `:binary_id` fields
  are stored in the database as well as the type of the column in which these IDs will
  be stored. The possible values are:

  * `:string` - IDs are stored as strings, and the type of the column is `TEXT`. This is
    the default.
  * `:binary` - IDs are stored in their raw binary form, and the type of the column is `BLOB`.

  The main differences between the two formats are as follows:
  * When stored as binary, UUIDs require much less space in the database. IDs stored as
    strings require 36 bytes each, while IDs stored as binary only require 16 bytes.
  * Because SQLite does not have a dedicated UUID type, most clients cannot represent
    UUIDs stored as binary in a human readable format. Therefore, IDs stored as strings
    may be easier to work with if manual manipulation is required.

  ## Turso extensions

  ### Concurrent transactions

  With `journal_mode: :mvcc`, Turso supports `BEGIN CONCURRENT`: several write
  transactions can run at the same time and only conflict when they touch the
  same rows. Pass `mode: :concurrent` to `Repo.transaction/2`, or set
  `default_transaction_mode: :concurrent`:

      config :my_app, MyApp.Repo,
        database: "path/to/my/database.db",
        journal_mode: :mvcc,
        default_transaction_mode: :concurrent

  A transaction that loses a write-write conflict fails with a
  `Sediment.Error` whose message is `"Write-write conflict"` and is rolled back.
  A commit that can't get its turn fails with `"Database busy"`, and a transaction
  that overlaps another connection's DDL (a migration) can fail with
  `"Database schema changed"`. All three are safe to retry, since nothing of the
  transaction was written; the README's "Concurrent transactions" section has a
  retry helper.

  Turso doesn't allow DDL inside `BEGIN CONCURRENT`. When the default mode is
  `:concurrent` and a transaction's first statement is DDL, as in migrations, the
  driver begins it as `BEGIN IMMEDIATE` instead, so migrations work unchanged and stay
  atomic. A migration that writes data before its first DDL statement (DDL commands
  are queued until the end of the migration unless you call `flush/0`) fails with
  `DDL statements require an exclusive transaction` and is rolled back; run it with
  `Ecto.Migrator.with_repo(repo, fun, default_transaction_mode: :immediate)`.

  ### Encryption

      config :my_app, MyApp.Repo,
        database: "path/to/my/database.db",
        encryption: [cipher: "aegis256", key: "<64 hex characters>"]

  The whole database file is encrypted. Opening it without the right key fails.
  `Sediment.S3.generate_key/0` (or `openssl rand -hex 32`) generates a key.

  ### S3-backed databases

  With the `:s3` option, an S3 bucket/prefix is the durable state of record and the
  local file is a working copy, restored from S3 when the repo starts. S3-backed
  databases are encrypted by default: the repo needs `:encryption` with a key (the
  data in the bucket is encrypted too), or `encryption: false` to store it
  unencrypted; without either it refuses to connect.

      config :my_app, MyApp.Repo,
        database: "/var/lib/my_app/app.db",
        encryption: [cipher: "aegis256", key: System.fetch_env!("DATABASE_ENCRYPTION_KEY")],
        s3: [
          bucket: "my-bucket",
          prefix: "prod/app",
          region: "eu-central-1",
          access_key_id: "...",
          secret_access_key: "..."
        ]

  Durability is asynchronous by default (`durability: :async` in the `:s3` options):
  a commit returns once it is committed locally and reaches S3 in the background
  shortly after, so a crash can lose the last commits (a restore is always a prefix
  of the commits, in order). To wait until a commit is durable, pass `sync: true` to
  any repo function:

      Repo.insert!(changeset, sync: true)
      Repo.transaction(fn -> ... end, sync: true)

  `s3_flush/2` waits until everything committed so far is durable, and
  `durability: :sync` makes every commit wait for S3.

  S3-backed databases use `journal_mode: :mvcc` and `busy_timeout: 15_000` by default.
  Only one node may write at a time; see `Sediment.S3` for all options, leases and
  snapshots.

  `checkpoint/2` uploads a snapshot now. `s3_restore/3` restores the latest state, or the
  state at a point in time (with `retain_epochs: n` in the `:s3` options), into a standalone
  file without affecting the writer; see also `mix ecto.sediment.s3.restore`.

  `storage_up/1`, `storage_down/1` and `storage_status/1` operate on the local working
  copy: `storage_down/1` does **not** delete data in S3 (`s3_destroy/2` does), and a
  repo whose local file was removed is restored from S3 on the next start.
  `s3_exists?/1` tells whether a location holds a database; `must_exist: true` in the
  `:s3` options makes a repo refuse to start with a new, empty one.

  ### Vectors

  See `Ecto.Adapters.Sediment.Vector` and `Ecto.Adapters.Sediment.Vector.Query`.

  ## Limitations and caveats

  There are some limitations when using Ecto with SQLite that one needs
  to be aware of. The ones listed below are specific to Ecto usage, but it
  is encouraged to also view the guidance on [when to use SQLite][4] provided
  by the SQLite documentation, as well.

  ### In memory robustness

  When using the Sediment adapter with the database set to `:memory` it
  is possible that a crash in a process performing a query in the Repo will
  cause the database to be destroyed. This makes the `:memory` function
  unsuitable when it is expected to survive potential process crashes (for
  example a crash in a Phoenix request)

  ### Async Sandbox testing

  The Sediment adapter does not support async tests when used with
  `Ecto.Adapters.SQL.Sandbox`, in any journal mode. Sandbox transactions use a plain
  `BEGIN` (even with `default_transaction_mode: :concurrent`), so only one of them can
  write at a time, which doesn't work with the Sandbox approach of wrapping each test
  in a transaction. This is the same as ecto_sqlite3.

  ### Decimal precision

  As in ecto_sqlite3, `:decimal` columns are created as `DECIMAL`, which has
  NUMERIC affinity: SQLite stores a decimal as a REAL when it looks like one, so
  only about 15 significant digits survive. For exact decimals, store them in a
  text column (`add :amount, :text`) and keep the `:decimal` field type.

  ### LIKE match on BLOB columns

  Unlike ecto_sqlite3 (which builds SQLite with `SQLITE_LIKE_DOESNT_MATCH_BLOBS`),
  Turso matches `LIKE` patterns against `BLOB` columns.

  ### Case sensitivity

  `LIKE` is case-insensitive (for ASCII characters). Turso does not implement the
  `:case_sensitive_like` option.

  However, for equality comparison, case sensitivity is always _on_.
  If you want to make a column not be case sensitive, for email storage for example, you
  can make it case insensitive by using the [`COLLATE NOCASE`][6] option in SQLite. This
  is configured via the `:collate` option.

  So instead of:

      add :email, :string

  You would do:

      add :email, :string, collate: :nocase

  ### Check constraints

  Turso supports specifying check constraints on the table or on the column definition.
  We currently only support adding a check constraint via a column definition, since the
  table definition approach only works at table-creation time and cannot be added at
  table-alter time. You can see more information in the SQLite
  [CREATE TABLE documentation](https://sqlite.org/lang_createtable.html).

  Because of this, you cannot add a constraint via the normal `Ecto.Migration.constraint/3`
  method, as that operates via `ALTER TABLE ADD CONSTRAINT`, and this type of `ALTER TABLE`
  operation Turso does not support. You can however get the full functionality by
  adding a constraint at the column level, specifying the name and expression. Per the
  SQLite documentation, there is no _functional_ difference between a column or table
  constraint.

  Thus, to add a check constraint for a new column:

      add :email, :string, check: %{name: "test_constraint", expr: "email != 'test@example.com'"}

  ### Handling foreign key constraints in changesets

  Unlike other databases, Turso does not provide the precise name of
  the constraint violated, but only the columns within that constraint (if it provides
  any information at all). Because of this, changeset functions like
  `Ecto.Changeset.foreign_key_constraint/3` may not work at all.

  This is because the above functions depend on the Ecto Adapter returning the name of
  the violated constraint, which you annotate in your changeset so that Ecto can convert
  the constraint violation into the correct updated changeset when the constraint is hit
  during a `c:Ecto.Repo.update/2` or `c:Ecto.Repo.insert/2` operation. Since we cannot
  get the name of the violated constraint back from Turso at `INSERT` or `UPDATE`
  time, there is no way to effectively use these changeset functions. This is a Turso
  limitation.

  See [this GitHub issue](https://github.com/elixir-sqlite/ecto_sqlite3/issues/42) for
  more details.

  ### Schemaless queries

  Using [schemaless Ecto queries][7] will not work well with SQLite. This is because
  the Ecto SQLite adapter relies heavily on the schema to support a rich array of Elixir
  types, despite the fact SQLite only has [five storage classes][5]. The query will still
  work and return data, but you will need to do this mapping on your own.

  ### Transaction mode

  By default, [SQLite transactions][8] run in `DEFERRED` mode. However, in 
  web applications with a balanced load of reads and writes, using  `IMMEDIATE` 
  mode may yield better performance.

  Here are several ways to specify a different transaction mode:

  **Pass `mode: :immediate` to `Repo.transaction/2`:** Use this approach to set 
  the transaction mode for individual transactions.

      Multi.new()
      |> Multi.run(:example, fn _repo, _changes_so_far ->
        # ... do some work ...
      end)
      |> Repo.transaction(mode: :immediate)

  **Define custom transaction functions:** Create wrappers, such as 
  `Repo.immediate_transaction/2` or `Repo.deferred_transaction/2`, to apply
  different modes where needed.

      defmodule MyApp.Repo do
        def immediate_transaction(fun_or_multi) do
          transaction(fun_or_multi, mode: :immediate)
        end

        def deferred_transaction(fun_or_multi) do
          transaction(fun_or_multi, mode: :deferred)
        end
      end

  **Set a global default:** Configure `:default_transaction_mode` to apply a 
  preferred mode for all transactions, unless explicitly passed a different
  `:mode` to `Repo.transaction/2`.

      config :my_app, MyApp.Repo,
        database: "path/to/my/database.db",
        default_transaction_mode: :immediate

  [4]: https://www.sqlite.org/whentouse.html
  [5]: https://www.sqlite.org/datatype3.html
  [6]: https://www.sqlite.org/datatype3.html#collating_sequences
  [7]: https://hexdocs.pm/ecto/schemaless-queries.html
  [8]: https://www.sqlite.org/lang_transaction.html#deferred_immediate_and_exclusive_transactions
  """

  use Ecto.Adapters.SQL,
    driver: :sediment

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  require Logger

  alias Ecto.Adapters.Sediment.Codec
  alias Ecto.Adapters.Sediment.Connection
  alias Ecto.Adapters.Sediment.Structure

  @impl Ecto.Adapter.Storage
  def storage_down(options) do
    db_path = Keyword.fetch!(options, :database)
    warn_s3_kept(options[:s3])
    mvcc? = mvcc_file?(db_path)

    case File.rm(db_path) do
      :ok ->
        File.rm(db_path <> "-shm")
        File.rm(db_path <> "-wal")
        File.rm(db_path <> "-tshm")
        # The MVCC log is named after the file without its extension, so it
        # may be another database file's (app.db next to app.sqlite); Sediment
        # only lets an MVCC database use a log that is its own.
        if mvcc?, do: File.rm(Path.rootname(db_path) <> ".db-log")
        :ok

      _otherwise ->
        {:error, :already_down}
    end
  end

  # Byte 18 of the header (the read version) is 255 in MVCC mode.
  defp mvcc_file?(path) do
    match?(
      {:ok, <<_::binary-size(18), 255, _::binary>>},
      File.open(path, [:read, :binary], &IO.binread(&1, 20))
    )
  end

  defp warn_s3_kept(nil), do: :ok

  defp warn_s3_kept(s3) do
    Logger.warning(
      "storage_down only removes the local working copy; the database in S3 " <>
        "(bucket #{inspect(s3[:bucket])}, prefix #{inspect(s3[:prefix] || "")}) is kept; " <>
        "Ecto.Adapters.Sediment.s3_destroy/2 deletes it"
    )
  end

  @impl Ecto.Adapter.Storage
  def storage_status(options) do
    db_path = Keyword.fetch!(options, :database)

    if File.exists?(db_path) do
      :up
    else
      :down
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_up(options) do
    database = Keyword.get(options, :database)
    pool_size = Keyword.get(options, :pool_size)

    cond do
      is_nil(database) ->
        raise ArgumentError,
              """
              No SQLite database path specified. Please check the configuration for your Repo.
              Your config/*.exs file should have something like this in it:

                config :my_app, MyApp.Repo,
                  adapter: Ecto.Adapters.Sediment,
                  database: "/path/to/sqlite/database"
              """

      File.exists?(database) ->
        {:error, :already_up}

      database == ":memory:" && pool_size != 1 ->
        raise ArgumentError, """
        In memory databases must have a pool_size of 1
        """

      true ->
        case options
             |> Connection.normalize_opts()
             |> Sediment.Connection.connect() do
          {:ok, state} -> Sediment.Connection.disconnect(:normal, state)
          {:error, error} -> {:error, Exception.message(error)}
        end
    end
  end

  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction?, do: true

  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _options, fun) do
    fun.()
  end

  @impl Ecto.Adapter.Structure
  def structure_dump(default, config) do
    path = config[:dump_path] || Path.join(default, "structure.sql")

    with {:ok, contents} <- dump_schema(config),
         {:ok, versions} <- dump_versions(config) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents <> versions)
      {:ok, path}
    end
  end

  @impl Ecto.Adapter.Structure
  def structure_load(default, config) do
    path = config[:dump_path] || Path.join(default, "structure.sql")

    case Structure.load(config, path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs `args` against the database, emulating the `sqlite3` command line tool.

  Each argument is either an SQL statement, whose rows are printed separated
  by `|`, or the `.schema` command. Returns `{output, exit_status}` like
  `System.cmd/3`. Unlike ecto_sqlite3, no external executable is needed.
  """
  @impl Ecto.Adapter.Structure
  def dump_cmd(args, _opts \\ [], config) when is_list(config) and is_list(args) do
    Structure.run(args, config)
  end

  @doc """
  Checkpoints the database of `repo`.

  For S3-backed databases this uploads a snapshot to S3 (incremental: only
  the segments changed since the last one) and starts a new log epoch, which keeps restores fast. For other databases it checkpoints
  the WAL into the database file. Also available as `mix ecto.sediment.checkpoint`.

  It waits (up to 15 s) until transactions open on other connections of the
  repo have finished, and for S3 until the snapshot is uploaded. `opts` is
  accepted for compatibility.
  """
  @spec checkpoint(Ecto.Repo.t() | pid(), Keyword.t()) :: :ok | {:error, Exception.t()}
  def checkpoint(repo, _opts \\ []) do
    # The driver's snapshot checkpoints and waits for the upload (turso's
    # checkpoint itself leaves S3 work to the background); for other
    # databases it has checkpointed and reports that there's no S3.
    case Sediment.S3.snapshot(pool(repo)) do
      :ok ->
        :ok

      {:error, "not an s3 database"} ->
        :ok

      {:error, reason} when is_binary(reason) ->
        {:error, %Sediment.Error{message: reason}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Brings a read-only replica repo (`s3: [mode: :replica, ...]`) up to date
  with the latest state in S3.

  The connection that runs the call refreshes at once; the other connections
  of the pool refresh before their next query outside a transaction. See
  `Sediment.S3.refresh/1`. `repo` is a repo module or a repo pid.
  """
  @spec s3_refresh(Ecto.Repo.t() | pid()) :: {:ok, map()} | {:error, term()}
  def s3_refresh(repo), do: Sediment.S3.refresh(pool(repo))

  @doc """
  Returns the S3 state of an S3-backed repo (writer or replica), see
  `Sediment.S3.info/1`.
  """
  @spec s3_info(Ecto.Repo.t() | pid()) :: {:ok, map()} | {:error, term()}
  def s3_info(repo), do: Sediment.S3.info(pool(repo))

  @doc """
  Waits until everything committed so far through `repo` is durable in S3,
  at most `timeout` milliseconds.

  With `durability: :async` (the default for S3-backed repos) a commit
  returns once it is in the local log, and a background uploader makes it
  durable in S3 shortly after (within `:max_lag_ms`). Call `s3_flush/2`
  before an operation that must not lose recent commits, such as handing
  over to another node. Returns `:ok`, or `{:error, reason}` when the timeout
  expires or the writer is fenced (the reason says up to which log offset the
  data is durable). With `durability: :sync` every commit is already durable
  and it returns at once. See also the `sync: true` option of
  `c:Ecto.Repo.transaction/2` and the other repo functions, and
  `Sediment.S3.flush/2`.
  """
  @spec s3_flush(Ecto.Repo.t() | pid(), timeout()) :: :ok | {:error, term()}
  def s3_flush(repo, timeout \\ 15_000), do: Sediment.S3.flush(pool(repo), timeout)

  @doc """
  Acknowledges that commits of `repo`'s database were lost, so that
  `s3_flush/2` and `sync: true` succeed again. Returns `{:ok, loss}` with
  what was lost (the `lost` field of `s3_info/1`), or `{:ok, nil}`.

  With `durability: :async`, commits still queued when the writer is fenced,
  or when it stops while S3 is unreachable, are lost. From then on
  `s3_flush/2` and `sync: true` fail with an error naming the lost range, so
  the loss can't go unnoticed; call this once the application has dealt with
  it. See `Sediment.S3.acknowledge_loss/1`.
  """
  @spec s3_acknowledge_loss(Ecto.Repo.t() | pid()) ::
          {:ok, map() | nil} | {:error, term()}
  def s3_acknowledge_loss(repo), do: Sediment.S3.acknowledge_loss(pool(repo))

  # A repo module resolves to its current dynamic repo (itself, a name or a
  # pid) once; a pid or a dynamic repo name is looked up directly.
  defp pool(repo) do
    dynamic =
      if is_atom(repo) and Code.ensure_loaded?(repo) and
           function_exported?(repo, :get_dynamic_repo, 0),
         do: repo.get_dynamic_repo(),
         else: repo

    Ecto.Adapter.lookup_meta(dynamic).pid
  end

  @doc """
  Restores the S3-backed database of `repo` into a standalone file at `path`.

  The restore reads S3 only: it neither takes the writer lease nor writes to
  S3, so it is safe while the application is running. The result is a
  standalone Turso database file (open it without the `:s3` option). Also
  available as `mix ecto.sediment.s3.restore`.

  `path` must not exist (nor its `-wal` or `.db-log` files): the restore
  returns `{:error, "restore target exists: ..."}` instead of replacing a
  file, which might be the repo's own working copy.

  `repo` is a repo module (its `:s3` and `:encryption` configuration are used)
  or a keyword list of `:s3` options.

  ## Options

    * `:at` - a `DateTime`: restore the state as of that moment.
    * `:epoch` - an epoch sequence number.
    * `:encryption` - `[cipher: ..., key: ...]` of an encrypted database, or
      `false` for an unencrypted one; defaults to the repo's `:encryption` option.
      The restored file stays encrypted with the same key, so open it with the
      same `:encryption`.

  Point-in-time restores reach back as far as the epochs the writer retains,
  see the `:retain_epochs` option of `Sediment.S3`. Without options, the
  latest state is restored.
  """
  @spec s3_restore(Ecto.Repo.t() | Keyword.t(), Path.t(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def s3_restore(repo_or_s3, path, opts \\ [])

  def s3_restore(repo, path, opts) when is_atom(repo) do
    config = repo.config()

    case config[:s3] do
      nil ->
        {:error, "#{inspect(repo)} is not configured with :s3"}

      s3 ->
        # `encryption: false` (an unencrypted S3 database) is forwarded too
        opts =
          if Keyword.has_key?(config, :encryption),
            do: Keyword.put_new(opts, :encryption, config[:encryption]),
            else: opts

        s3_restore(s3, path, opts)
    end
  end

  def s3_restore(s3, path, opts) when is_list(s3) do
    File.mkdir_p!(Path.dirname(path))
    s3 = Connection.normalize_opts(s3: s3)[:s3]
    Sediment.S3.restore(path, s3, opts)
  end

  @doc """
  Imports an existing database file into the empty S3 location of `repo`, as
  its new database (see `Sediment.S3.import/3`): its schema and rows are
  copied into a new MVCC database, AUTOINCREMENT sequences, indexes, views,
  triggers and foreign keys included. Also available as
  `mix ecto.sediment.s3.import`.

  `path` defaults to the repo's `:database`: stop the application (every
  writer of the file) first, import, then start it with the `:s3`
  configuration. The file is never written to; the repo's first start
  restores the imported database over it.

  `repo` is a repo module (its `:s3`, `:database` and `:encryption`
  configuration are used) or a keyword list of `:s3` options (then `path` is
  required).

  ## Options

    * `:verify` - `:checksum` (default) or `:restore`, see
      `Sediment.S3.import/3`.
    * `:encryption` - the new database's key, or `false` to store it
      unencrypted; defaults to the repo's `:encryption`.
    * `:source_encryption` - the key of an encrypted source file; defaults to
      the repo's `:encryption` (a plaintext source is read without it).
  """
  @spec s3_import(Ecto.Repo.t() | Keyword.t(), Path.t() | nil, Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def s3_import(repo_or_s3, path \\ nil, opts \\ [])

  def s3_import(repo, path, opts) when is_atom(repo) do
    config = repo.config()

    case config[:s3] do
      nil ->
        {:error, "#{inspect(repo)} is not configured with :s3"}

      s3 ->
        opts =
          case Keyword.fetch(config, :encryption) do
            {:ok, encryption} when is_list(encryption) ->
              opts
              |> Keyword.put_new(:encryption, encryption)
              |> Keyword.put_new(:source_encryption, encryption)

            # an unencrypted repo: the S3 database too, from a plaintext source
            {:ok, false} ->
              Keyword.put_new(opts, :encryption, false)

            _ ->
              opts
          end

        s3_import(s3, path || config[:database], opts)
    end
  end

  def s3_import(s3, path, opts) when is_list(s3) and is_binary(path) do
    s3 = Connection.normalize_opts(s3: s3)[:s3]
    Sediment.S3.import(path, s3, opts)
  end

  @doc """
  Whether the S3 location of `repo` holds a database (see
  `Sediment.S3.exists?/1`): `false` when it holds none yet or the database
  was destroyed. Only reads S3. Raises `Sediment.Error` when the store
  can't be read.

  `repo` is a repo module (its `:s3` configuration is used) or a keyword
  list of `:s3` options, for example of a dynamic repo.

  To refuse to create an empty database at a location that should hold one
  (a tenant you know exists), set `must_exist: true` in the `:s3` options
  instead: the repo then fails to connect rather than start empty.
  """
  @spec s3_exists?(Ecto.Repo.t() | Keyword.t()) :: boolean()
  def s3_exists?(repo_or_s3)

  def s3_exists?(repo) when is_atom(repo) do
    case repo.config()[:s3] do
      nil -> raise ArgumentError, "#{inspect(repo)} is not configured with :s3"
      s3 -> s3_exists?(s3)
    end
  end

  def s3_exists?(s3) when is_list(s3) do
    Sediment.S3.exists?(Connection.normalize_opts(s3: s3)[:s3])
  end

  @doc """
  Destroys the S3-backed database of `repo` (see `Sediment.S3.destroy/2`):
  afterwards no open, replica or restore finds it, and its snapshots and log
  are deleted. The repo's next start creates a new, empty database there.

  Stop the repo everywhere first: destroy returns an error while the
  database is open in this VM, and `{:error, "s3 lease held by ..."}` while
  a writer elsewhere holds the lease. Local files are not touched;
  `storage_down/1` (`mix ecto.drop`) removes the working copy. Two small
  objects without data stay at the prefix (a marker and `lease.json`).

  `repo` is a repo module (its `:s3` configuration is used) or a keyword
  list of `:s3` options, for example of a dynamic repo.

  ## Options

    * `:force` - take the lease even while a writer holds it, fencing that
      writer (its commits not yet uploaded are lost with the database).
  """
  @spec s3_destroy(Ecto.Repo.t() | Keyword.t(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def s3_destroy(repo_or_s3, opts \\ [])

  def s3_destroy(repo, opts) when is_atom(repo) do
    case repo.config()[:s3] do
      nil -> {:error, "#{inspect(repo)} is not configured with :s3"}
      s3 -> s3_destroy(s3, opts)
    end
  end

  def s3_destroy(s3, opts) when is_list(s3) do
    Sediment.S3.destroy(Connection.normalize_opts(s3: s3)[:s3], opts)
  end

  @doc """
  Exports the repo's database to a new plain SQLite file at `dest` (see
  `Sediment.export_sqlite/3` and sediment's "Leaving Sediment" guide). Also
  available as `mix ecto.sediment.export_sqlite`.

  An S3 repo is exported from its S3 prefix, which is only read, so the
  application may keep running; another repo from its `:database` file
  (stop the application first). The repo's `:encryption` (a key, or `false`)
  is used for the source.

  `repo` is a repo module (its `:s3`, `:database` and `:encryption`
  configuration are used) or a keyword list of `:s3` options, for example of
  a dynamic repo.

  ## Options

    * `:source` - export this database file instead (with a repo module).
    * `:encryption` - the source's key, or `false` for an unencrypted
      database; defaults to the repo's `:encryption`.
    * `:drop_fts` - leave Turso FTS indexes out of the copy (without it, a
      database with any is refused).
  """
  @spec export_sqlite(Ecto.Repo.t() | Keyword.t(), Path.t(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def export_sqlite(repo_or_s3, dest, opts \\ [])

  def export_sqlite(repo, dest, opts) when is_atom(repo) do
    config = repo.config()
    {source, opts} = Keyword.pop(opts, :source)

    opts =
      case Keyword.fetch(config, :encryption) do
        {:ok, encryption} -> Keyword.put_new(opts, :encryption, encryption)
        :error -> opts
      end

    case {source, config[:s3]} do
      {nil, nil} -> Sediment.export_sqlite(config[:database], dest, opts)
      {nil, s3} -> export_sqlite(s3, dest, opts)
      {path, _} -> Sediment.export_sqlite(path, dest, opts)
    end
  end

  def export_sqlite(s3, dest, opts) when is_list(s3) do
    s3 = Connection.normalize_opts(s3: s3)[:s3]
    Sediment.export_sqlite(nil, dest, Keyword.put(opts, :from_s3, s3))
  end

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()

  def autogenerate(:binary_id) do
    case Application.get_env(:ecto_sediment, :binary_id_type, :string) do
      :string -> Ecto.UUID.generate()
      :binary -> Ecto.UUID.bingenerate()
    end
  end

  ##
  ## Loaders
  ##

  @default_datetime_type :iso8601

  @impl Ecto.Adapter
  def loaders(:boolean, type) do
    [&Codec.bool_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:naive_datetime_usec, type) do
    [&Codec.naive_datetime_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:time, type) do
    [&Codec.time_decode/1, type]
  end

  # Not in ecto_sqlite3, which can't load :time_usec fields
  @impl Ecto.Adapter
  def loaders(:time_usec, type) do
    [&Codec.time_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:utc_datetime_usec, type) do
    [&Codec.utc_datetime_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:utc_datetime, type) do
    [&Codec.utc_datetime_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:naive_datetime, type) do
    [&Codec.naive_datetime_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:date, type) do
    [&Codec.date_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders({:map, _}, type) do
    [&Codec.json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
  end

  @impl Ecto.Adapter
  def loaders({:array, _}, type) do
    [&Codec.json_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:map, type) do
    [&Codec.json_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:float, type) do
    [&Codec.float_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:decimal, type) do
    [&Codec.decimal_decode/1, type]
  end

  @impl Ecto.Adapter
  def loaders(:binary_id, type) do
    case Application.get_env(:ecto_sediment, :binary_id_type, :string) do
      :string -> [type]
      :binary -> [Ecto.UUID, type]
    end
  end

  @impl Ecto.Adapter
  def loaders(:uuid, type) do
    case Application.get_env(:ecto_sediment, :uuid_type, :string) do
      :string -> []
      :binary -> [type]
    end
  end

  @impl Ecto.Adapter
  def loaders(primitive_type, ecto_type) do
    loader_from_extension(primitive_type, ecto_type)
  end

  ##
  ## Dumpers
  ##

  @impl Ecto.Adapter
  def dumpers(:binary, type) do
    [type, &Codec.blob_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(:boolean, type) do
    [type, &Codec.bool_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(:decimal, type) do
    [type, &Codec.decimal_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(:binary_id, type) do
    case Application.get_env(:ecto_sediment, :binary_id_type, :string) do
      :string -> [type]
      :binary -> [type, Ecto.UUID]
    end
  end

  @impl Ecto.Adapter
  def dumpers(:uuid, type) do
    case Application.get_env(:ecto_sediment, :uuid_type, :string) do
      :string -> []
      :binary -> [type]
    end
  end

  @impl Ecto.Adapter
  def dumpers(:time, type) do
    [type, &Codec.time_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(:time_usec, type) do
    [type, &Codec.time_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(:utc_datetime, type) do
    dt_type =
      Application.get_env(:ecto_sediment, :datetime_type, @default_datetime_type)

    [type, &Codec.utc_datetime_encode(&1, dt_type)]
  end

  @impl Ecto.Adapter
  def dumpers(:utc_datetime_usec, type) do
    dt_type =
      Application.get_env(:ecto_sediment, :datetime_type, @default_datetime_type)

    [type, &Codec.utc_datetime_encode(&1, dt_type)]
  end

  @impl Ecto.Adapter
  def dumpers(:naive_datetime, type) do
    dt_type =
      Application.get_env(:ecto_sediment, :datetime_type, @default_datetime_type)

    [type, &Codec.naive_datetime_encode(&1, dt_type)]
  end

  @impl Ecto.Adapter
  def dumpers(:naive_datetime_usec, type) do
    dt_type =
      Application.get_env(:ecto_sediment, :datetime_type, @default_datetime_type)

    [type, &Codec.naive_datetime_encode(&1, dt_type)]
  end

  @impl Ecto.Adapter
  def dumpers({:array, _}, type) do
    [type, &Codec.json_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers({:map, _}, type) do
    [&Ecto.Type.embedded_dump(type, &1, :json), &Codec.json_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(:map, type) do
    [type, &Codec.json_encode/1]
  end

  @impl Ecto.Adapter
  def dumpers(primitive_type, ecto_type) do
    dumper_from_extension(primitive_type, ecto_type)
  end

  ##
  ## HELPERS
  ##

  defp dump_versions(config) do
    Structure.dump_versions(config, config[:migration_source] || "schema_migrations")
  end

  defp dump_schema(config), do: Structure.dump_schema(config)

  defp extensions do
    Application.get_env(:ecto_sediment, :type_extensions, [])
  end

  defp loader_from_extension(primitive_type, ecto_type) do
    loader_from_extension(extensions(), primitive_type, ecto_type)
  end

  defp loader_from_extension([], _primitive_type, ecto_type), do: [ecto_type]

  defp loader_from_extension([extension | other_extensions], primitive_type, ecto_type) do
    case extension.loaders(primitive_type, ecto_type) do
      nil -> loader_from_extension(other_extensions, primitive_type, ecto_type)
      loader -> loader
    end
  end

  defp dumper_from_extension(primitive_type, ecto_type) do
    dumper_from_extension(extensions(), primitive_type, ecto_type)
  end

  defp dumper_from_extension([], _primitive_type, ecto_type), do: [ecto_type]

  defp dumper_from_extension([extension | other_extensions], primitive_type, ecto_type) do
    case extension.dumpers(primitive_type, ecto_type) do
      nil -> dumper_from_extension(other_extensions, primitive_type, ecto_type)
      dumper -> dumper
    end
  end
end
