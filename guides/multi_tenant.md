# Multi-tenant apps: one database per tenant

With one database per tenant, each tenant's data lives in its own file (and,
with `:s3`, under its own S3 prefix). Tenants can't see each other's rows by
accident, a tenant can be backed up, restored, exported or deleted on its
own, and a large tenant doesn't slow down the others. This guide shows one
way to run that with a single repo module, and what it costs.

The code below is the reference: the test suite evaluates this guide's code
block and runs the patterns described here against it
(`test/ecto/integration/multi_tenant_test.exs`), and the resource numbers come
from `bench/multi_tenant.exs`.

## The pattern

One repo module serves every tenant. Each tenant gets its own repo instance,
started with `name: nil` (a dynamic repo, see `c:Ecto.Repo.put_dynamic_repo/1`)
and its own configuration. A small supervisor starts a tenant's repo on first
use, runs its migrations, and stops it after a period without use:

* `MyApp.Tenants.with_tenant/2` runs a function with `MyApp.Repo` pointing at
  the tenant's database. Inside it, use `MyApp.Repo` as usual.
* A `Registry` maps tenant ids to the process that owns the tenant's repo; a
  `DynamicSupervisor` starts those processes. Concurrent first uses of a
  tenant start it once.
* Each tenant process stops itself after `:idle_after` milliseconds without a
  `with_tenant/2` call. Stopping the repo uploads its pending commits and
  releases its S3 lease.

Configure it with a function that returns a tenant's repo options, the
migrations directory, and the idle timeout, and start `MyApp.Tenants` in your
application's supervision tree:

```elixir
# config/runtime.exs
config :my_app, MyApp.Tenants,
  repo: &MyApp.TenantConfig.repo/1,
  migrations_path: Application.app_dir(:my_app, "priv/tenant_migrations"),
  idle_after: :timer.minutes(15)

# lib/my_app/application.ex, in children:
MyApp.Tenants
```

A request then works on one tenant:

```elixir
MyApp.Tenants.with_tenant(tenant_id, fn ->
  MyApp.Repo.all(MyApp.Note)
end)
```

`MyApp.Repo` is an ordinary repo module (`use Ecto.Repo, otp_app: :my_app,
adapter: Ecto.Adapters.Sediment`). The tenants' options come from the `:repo`
function; `config :my_app, MyApp.Repo` only needs what all tenants share and
what migrations read from the repo module, such as `migration_primary_key`.

## Reference code

<!-- test/ecto/integration/multi_tenant_test.exs evaluates this block -->
```elixir
defmodule MyApp.Tenants do
  @moduledoc """
  One database per tenant: starts a tenant's repo on first use, migrates it,
  and stops it after `:idle_after` milliseconds without use.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Compile the migrations once: Ecto.Migrator.run/4 with a path would
    # recompile the files for every tenant it migrates.
    path = Application.fetch_env!(:my_app, __MODULE__)[:migrations_path]

    migrations =
      for file <- Enum.sort(Path.wildcard(Path.join(path, "*.exs"))) do
        [version | _] = String.split(Path.basename(file), "_")
        [{module, _} | _] = Code.compile_file(file)
        {String.to_integer(version), module}
      end

    :persistent_term.put({__MODULE__, :migrations}, migrations)

    children = [
      {Registry, keys: :unique, name: MyApp.Tenants.Registry},
      {DynamicSupervisor, name: MyApp.Tenants.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Runs `fun` with `MyApp.Repo` pointing at the tenant's database."
  def with_tenant(tenant_id, fun) do
    repo = MyApp.Tenants.Tenant.checkout(tenant_id)
    previous = MyApp.Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      MyApp.Repo.put_dynamic_repo(previous)
    end
  end

  @doc "Stops the tenant's repo, if it runs (pending commits are uploaded first)."
  def stop(tenant_id) do
    case Registry.lookup(MyApp.Tenants.Registry, tenant_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(MyApp.Tenants.Supervisor, pid)
      [] -> :ok
    end
  end
end

defmodule MyApp.Tenants.Tenant do
  @moduledoc false
  # Owns one tenant's repo: starts and migrates it, stops it when idle.
  use GenServer, restart: :transient

  def checkout(tenant_id) do
    pid =
      case Registry.lookup(MyApp.Tenants.Registry, tenant_id) do
        [{pid, _}] ->
          pid

        [] ->
          case DynamicSupervisor.start_child(MyApp.Tenants.Supervisor, {__MODULE__, tenant_id}) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end
      end

    GenServer.call(pid, :checkout)
  catch
    # stopped (idle, or MyApp.Tenants.stop/1) since the lookup: start it again
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> checkout(tenant_id)
  end

  def start_link(tenant_id) do
    name = {:via, Registry, {MyApp.Tenants.Registry, tenant_id}}
    GenServer.start_link(__MODULE__, tenant_id, name: name)
  end

  @impl true
  def init(tenant_id) do
    Process.flag(:trap_exit, true)
    config = Application.fetch_env!(:my_app, MyApp.Tenants)
    {:ok, repo} = MyApp.Repo.start_link(config[:repo].(tenant_id) ++ [name: nil])

    migrations = :persistent_term.get({MyApp.Tenants, :migrations})
    Ecto.Migrator.run(MyApp.Repo, migrations, :up, all: true, dynamic_repo: repo, log: false)

    idle_after = config[:idle_after]
    Process.send_after(self(), :idle?, idle_after)
    {:ok, %{repo: repo, idle_after: idle_after, used_at: now()}}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    {:reply, state.repo, %{state | used_at: now()}}
  end

  @impl true
  def handle_info(:idle?, state) do
    idle = now() - state.used_at

    if idle >= state.idle_after do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle?, state.idle_after - idle)
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, repo, reason}, %{repo: repo} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the repo uploads pending commits and releases the S3 lease
    if Process.alive?(state.repo), do: Supervisor.stop(state.repo)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```

Notes on the code:

* `with_tenant/2` marks the tenant as used when it starts. A call that runs
  longer than `:idle_after` can have its repo stopped underneath it, so keep
  `:idle_after` well above your longest request or job (minutes, not
  seconds).
* A tenant that stops between the `Registry` lookup and the call (idle, or
  `MyApp.Tenants.stop/1`) is started again by the `catch` in `checkout/1`.
* The migrations are compiled once, when `MyApp.Tenants` starts, and run for
  each tenant when its repo starts. `Ecto.Migrator.run/4` with a path instead
  of a list would recompile the files for every tenant.
* If a tenant's repo can't start (for example its S3 lease is held by
  another node, see "Several app nodes" below), `with_tenant/2` raises and
  the next call tries again.

## Per-tenant configuration

The `:repo` function returns everything that differs per tenant:

```elixir
defmodule MyApp.TenantConfig do
  def repo(tenant_id) do
    [
      database: Path.join(System.fetch_env!("TENANT_DATA_DIR"), "#{tenant_id}.db"),
      pool_size: 1,
      encryption: [cipher: "aegis256", key: MyApp.Secrets.tenant_key!(tenant_id)],
      s3: [
        bucket: System.fetch_env!("S3_BUCKET"),
        prefix: "tenants/#{tenant_id}/",
        owner: System.fetch_env!("S3_OWNER")
      ]
    ]
  end
end
```

* **Database path.** One file per tenant. With `:s3` the file is only a
  working copy and can live on local, non-persistent disk; without `:s3` it
  is the database and needs a persistent volume and backups.
* **S3 prefix.** One prefix per tenant in a shared bucket is the simple
  choice: request costs are per request, not per bucket, and one set of
  credentials covers all tenants. A bucket per tenant only helps when tenants
  need separate credentials, regions or billing.
* **Pool size.** 1 or 2 per tenant. Each connection has its own page cache
  (up to `cache_size`, 64 MB by default, allocated as pages are read), and
  a tenant's commits are serialized anyway.
* **Tenant ids** end up in file names and S3 prefixes: use ids you control
  (database ids, UUIDs), not user input.

### Encryption keys

S3 databases need an `:encryption` key or `encryption: false`. With one key
per tenant, a leaked key exposes one tenant, and deleting a tenant's key makes
its data unreadable. With one key for all tenants, there's only one secret to
manage. ecto_sediment doesn't store or manage keys: keep them in a secret
store or KMS (one entry per tenant, or a master key from which you derive
tenant keys) and return them from the `:repo` function. Losing a tenant's key
loses that tenant's data, including every backup and point-in-time state in
S3. `Sediment.S3.generate_key/0` generates a key. Any number of different
keys can be open in one VM; every open of the same database file must use
the same key.

## Creating a tenant

There is no separate create step. The first `with_tenant/2` call for a new
tenant opens a database that doesn't exist yet: locally the file is created,
and with `:s3` an empty prefix becomes a new, empty database. The tenant's
migrations then run before the call continues.

On deploy, new migrations run when each tenant's repo next starts. Tenants
that are already open keep running the old schema until they are stopped and
reopened, so after deploying a migration either stop the open tenants
(`MyApp.Tenants.stop/1` for each) or migrate them in place:

```elixir
for {_id, pid, _, _} <- DynamicSupervisor.which_children(MyApp.Tenants.Supervisor) do
  # stop and let the next use start (and migrate) the tenant again
  DynamicSupervisor.terminate_child(MyApp.Tenants.Supervisor, pid)
end
```

To migrate every tenant ahead of their next use (for example before
switching code that needs the new columns), iterate over your tenant list and
call `MyApp.Tenants.with_tenant(id, fn -> :ok end)` for each, a few at a
time. Keep migrations backward compatible (add columns and tables, remove
them in a later deploy), since tenants migrate one by one.

An existing database, for example a tenant you're moving from another
system, becomes a tenant with `Ecto.Adapters.Sediment.s3_import/3`: import it
into the tenant's empty prefix before its first use. A tenant's repo is
dynamic, so pass its `:s3` options rather than `MyApp.Repo` (whose static
configuration has no tenant):

```elixir
config = MyApp.TenantConfig.repo(tenant_id)
Ecto.Adapters.Sediment.s3_import(config[:s3], "/imports/#{tenant_id}.db",
  encryption: config[:encryption]
)
```

Add `source_encryption:` for an encrypted source file. See "Importing an
existing database" in the [S3 guide](s3.md).

## Resources and idle shutdown

Measured with `bench/multi_tenant.exs` on a Linux machine (8 vCPUs, local
SSD, a local SeaweedFS server), `pool_size: 1`, each tenant opened, migrated
and written to once, 16 at a time:

| | Local (WAL) | S3 |
| --- | --- | --- |
| Memory (RSS) per open tenant | about 0.6 MB | about 1 MB |
| File descriptors per open tenant | 2 | 4 |
| OS threads per open tenant | none | 3 |
| Opening a tenant (with its migration) | 10-20 ms | 130-260 ms |
| 1,000 open tenants | 716 MB RSS, 2,019 fds | 1,082 MB RSS, 4,022 fds, 3,043 threads |
| S3 requests per idle open tenant | none | 360 per hour |

* Every open S3 tenant runs three OS threads (lease renewal, uploads,
  background snapshots; two with `durability: :sync`) and holds four file
  descriptors. At 1,000 open S3 tenants that's about 3,000 threads and 4,000
  file descriptors, and the idle tenants use about 7% of one CPU core
  (sediment's own measurement). Raise the process's file descriptor limit
  (`ulimit -n`) accordingly, and under systemd its `TasksMax`: the common
  default of about 4,900 tasks allows about 1,500 open S3 tenants per
  service. Plan for up to about 1,000 open S3 tenants per node, and use idle
  shutdown to stay below that.
* After tenants are closed, their memory isn't fully returned to the
  operating system, and with glibc it grows slowly over repeated open/close
  cycles (heap fragmentation, not a leak). Setting `MALLOC_ARENA_MAX=2` in
  the environment of a node with many tenants keeps it flat: in the
  benchmark, 8 rounds of opening and closing 500 tenants settled at the same
  RSS from the fifth round on.
* An idle open S3 tenant still renews its lease, with 1 PUT every
  `lease_ttl_ms / 3` (10 s by default): 360 requests per hour, about $1.30 a
  month on AWS S3 or Tigris. Stopping idle tenants removes that cost; a
  stopped tenant costs only its storage. See "Costs" below.

Stopping a tenant is safe: closing the repo uploads its pending async
commits (for up to `:close_timeout_ms`, 10 s by default) and releases its
lease, so the next start (on this node or another) restores everything. If S3
is unreachable for longer than that, the commits not uploaded yet are
reported as lost (see "Durability" in the [S3 guide](s3.md)); to be certain
before stopping, call `Ecto.Adapters.Sediment.s3_flush/2` and check its
result.

The idle timeout is the main knob: short enough that idle tenants don't
accumulate, long enough that an active tenant doesn't pay a restore (about
130 ms in the benchmark, more for large databases) on every request.

How many open tenants a node can hold depends mostly on their working sets
(the pages each tenant's connections have read); the fixed cost per open
tenant is in the table above.

## Several app nodes

Each S3 prefix has a single writer at a time, enforced by a lease. If two
nodes open the same tenant, the second one's repo can't connect: its
connections fail with `"s3 lease held by <owner> until <time>"` and keep
retrying, and the tenant's migrations (and `with_tenant/2`) fail on that
node. When the first node stops the tenant, the waiting node takes over by
itself. When the first node crashes, the waiting node takes over after the
lease expires (`lease_ttl_ms`, 30 s by default); async commits the crashed
node hadn't uploaded yet are lost, and everything committed with
`sync: true` or before a successful `s3_flush/2` is kept. These cases are
covered by the S3 test suite ("a second repo on the same prefix is refused
while the lease is held", "a waiting writer takes over by itself once the
holder stops", "migrations need the lease; a standby migrates once it takes
over").

So route each tenant to one node:

* **A tenant-to-node mapping.** Consistent hashing of the tenant id over the
  current node list, or a table that assigns tenants to nodes. A request that
  arrives at the wrong node is forwarded (an RPC to the owning node, or a
  redirect at the load balancer).
* **A cluster-wide registry.** With distributed Erlang, register the tenant
  processes globally (`:global`, or a library such as Horde) instead of in a
  local `Registry`, so a tenant runs on exactly one node and other nodes call
  it there.
* **One writer node, read replicas elsewhere.** Writes go to one node; other
  nodes open replicas of the tenant prefixes (`mode: :replica`) and refresh
  them with `Ecto.Adapters.Sediment.s3_refresh/1`. Replicas need no lease.

When nodes join or leave, tenants move: stop a tenant on its old node (which
uploads and releases its lease) before it's opened on the new one, or accept
that the new node waits until the old node's idle timeout stops it.

Give every node its own stable `owner` (for example its hostname or machine
id). A node that restarts with the same owner takes its lease back at once
instead of waiting for it to expire.

## Operations per tenant

* **Backup and point-in-time restore.** The tenant's S3 prefix is its backup.
  `Ecto.Adapters.Sediment.s3_restore/3` restores a tenant into a standalone
  file, at its latest state or at an earlier moment (with `retain_epochs` in
  the `:s3` options):

  ```elixir
  config = MyApp.TenantConfig.repo(tenant_id)
  Ecto.Adapters.Sediment.s3_restore(config[:s3], "/tmp/#{tenant_id}.db",
    encryption: config[:encryption]
  )
  ```

  It only reads S3, so it is safe while the tenant is open.
* **Export.** `Ecto.Adapters.Sediment.export_sqlite/3` writes a tenant's
  database as a plain SQLite file, for a tenant that leaves or for analysis
  with SQLite tools. Like the restore, it takes the tenant's `:s3` options
  and only reads S3:

  ```elixir
  config = MyApp.TenantConfig.repo(tenant_id)
  Ecto.Adapters.Sediment.export_sqlite(config[:s3], "/tmp/#{tenant_id}-sqlite.db",
    encryption: config[:encryption]
  )
  ```
* **Deleting a tenant.** Stop the tenant everywhere, then destroy its S3
  database and delete its local files:

  ```elixir
  :ok = MyApp.Tenants.stop(tenant_id)
  config = MyApp.TenantConfig.repo(tenant_id)
  {:ok, _} = Ecto.Adapters.Sediment.s3_destroy(config[:s3])
  for file <- Path.wildcard(config[:database] <> "*"), do: File.rm!(file)
  ```

  `s3_destroy/2` refuses while the tenant is open on this node or another
  node holds its lease (`force: true` fences that writer instead). It
  deletes the snapshots and log; two small objects without data stay at the
  prefix (a marker and `lease.json`), so a delayed write of the old database
  can never come back under the same id. `storage_down/1` (`mix ecto.drop`)
  only removes the local working copy. With per-tenant keys, deleting the
  key too makes any copy left behind (a restored file, a backup) unreadable.
* **Tenants that must exist.** Opening a prefix without a database creates a
  new, empty one, which is what a new tenant needs, but a mistyped bucket or
  prefix would then hand out empty databases for existing tenants. For
  tenants you know exist, add `must_exist: true` to their `:s3` options: the
  repo then fails to start instead. `Ecto.Adapters.Sediment.s3_exists?/1`
  answers the question without opening the database.
* **Moving a tenant** to another bucket or prefix: stop it, restore it into a
  file with `s3_restore/3`, and import that file into the new, empty prefix
  with `s3_import/3`. Then point the tenant's configuration at the new
  prefix and destroy the old one with `s3_destroy/2`. This writes a fresh database: the old
  prefix's retained epochs (point-in-time history) don't come along. Copying
  all objects of the prefix with S3 tools, while nothing is open on it,
  keeps the history: the layout is relative to the prefix.

## Costs

An S3 tenant costs storage plus requests: each commit is about one PUT and
one HEAD, and an open writer renews its lease 360 times an hour even when
idle. With many tenants, the idle renewals dominate unless idle tenants are
stopped. Per tenant and month, for 50 MB tenants of which 10% are active at
0.1 commits/s for 8 hours a day (2026 list prices):

| | Tigris | AWS S3 | Cloudflare R2 |
| --- | --- | --- | --- |
| Active, open around the clock | $1.79 | $1.78 | $1.60 |
| Idle, open around the clock | $1.32 | $1.32 | $1.18 |
| Idle, open, `lease_ttl_ms: 120_000` | $0.33 | $0.33 | $0.30 |
| Active, stopped when idle | $0.91 | $0.90 | $0.81 |
| Idle, stopped | $0.001 | $0.001 | $0.001 |

Averaged over those tenants that's about $1.36 per tenant and month with
every tenant open, and about $0.09 with idle tenants stopped. The two knobs:

* Idle shutdown (`:idle_after` above) removes the renewals of idle tenants.
* `lease_ttl_ms` in the `:s3` options: renewals happen every
  `lease_ttl_ms / 3`, so 120,000 cuts them to 90 an hour. The price is
  availability after a crash: another node can take over a crashed node's
  tenant only after the lease expires (the crashed node itself, restarted
  with the same `owner`, takes it back at once).

Sediment's S3 guide, ["Costs"](https://github.com/flmngco/sediment/blob/main/guides/s3.md#costs), has the request counts per
operation, the formula and the providers' prices.

## Limits and caveats

* Tenants on S3 use MVCC, where `AUTOINCREMENT` tables are
  much slower and conflict under concurrent writes; use integer primary keys
  in tenant migrations: `config :my_app, MyApp.Repo, migration_primary_key:
  [type: :integer]` (migrations read it from the repo module's configuration,
  not from a tenant's start options), or `primary_key: false` plus an
  `:integer` primary key column, as in the test suite.
* Schema changes across many tenants happen tenant by tenant, as each one
  starts. Keep migrations backward compatible for as long as some tenants may
  still run the previous schema, and avoid slow data migrations in tenant
  migrations: they delay each tenant's first request after a deploy.
* The lease allows one writer per tenant prefix: plan routing (see "Several
  app nodes") before running more than one node.
