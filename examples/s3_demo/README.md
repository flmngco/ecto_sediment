# s3_demo

A minimal Ecto app whose database lives in S3, using `ecto_sediment`. The local
file under `data/` is only a working copy: commits reach S3 in the background
(or before they return, with `sync: true`), so you can kill the app and delete
`data/`, and the next start restores everything that was durable: all commits
up to the last moment S3 had, with no gaps.

## Prerequisites

* Elixir 1.18+ and Erlang/OTP 27+.
* A Rust toolchain, 1.85 or newer (`rustup` is the easiest way): sediment
  builds a NIF.
* Docker, or any other S3-compatible server.
* `ecto_sediment` and `sediment` checked out next to each other: the demo
  runs against the code in this repository through path dependencies.

  ```
  some_dir/
    ecto_sediment/        # this repository; the demo is in examples/s3_demo
    sediment/
  ```

  In your own app, depend on the Hex package instead:
  `{:ecto_sediment, "~> 0.1"}` (it brings in `sediment`).

## 1. Start an S3 server

Any S3-compatible server works. For a local one, run SeaweedFS:

```sh
docker run -d --name seaweedfs -p 127.0.0.1:8333:8333 chrislusf/seaweedfs:4.48 server -s3
```

(If one is already listening on `127.0.0.1:8333`, skip this. The image is
pinned: newer SeaweedFS images refuse unsigned requests by default, which the
demo's bucket creation and its `"any"` credentials rely on.) With another
server (MinIO, AWS S3, ...), create the bucket yourself first: `mix setup`
can only create it on servers that accept unsigned requests, like SeaweedFS. The demo uses
bucket `s3-demo` and prefix `demo`; override with `S3_BUCKET`, `S3_PREFIX`,
`S3_ENDPOINT`, `S3_REGION`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
(see `config/runtime.exs`).

## 2. Set up

From this directory (the first compile builds the Rust NIF and takes a few
minutes):

```sh
export DATABASE_ENCRYPTION_KEY=$(openssl rand -hex 32)
mix deps.get
mix setup        # creates the bucket, the database (in S3) and runs migrations
```

S3 databases are encrypted, here with the key in `DATABASE_ENCRYPTION_KEY`:
keep it exported for all the following commands. Without it (or with another
key) the database in S3 can't be read, not even by a restore.

## 3. Write, crash, restore

Write notes one commit at a time, and kill the VM with `kill -9` while it's
writing:

```sh
mix demo.write 100000 &
sleep 5; kill -9 $!
```

The last line printed is the last commit that was acknowledged, e.g.
`committed 1115`. Every tenth note is written with `sync: true` and printed
as `committed 1110 (durable)`: that call returned only once the note was
durable in S3. The others return as soon as they are committed locally, and
reach S3 in the background a moment later (S3 repos use
`durability: :async` by default).

Now simulate losing the machine by deleting the local working copy:

```sh
mix demo.wipe
ls data            # gone
```

Start again. The database is restored from S3:

```sh
mix demo.show
# 1113 notes in the database
# no gaps
#   #1113: note 1113 written at ...
```

Every durable commit is there (up to note 1110 at least). The last few
acknowledged notes may be missing: `kill -9` stopped the VM before the
background uploader had sent them to S3. What you get back is always the
database as of some moment: notes 1 to N with no gaps, never a later note
without an earlier one. You may also see one more than the last printed
number: that commit reached S3, but the VM was killed before it printed its
line.

To lose nothing that was acknowledged, write with `sync: true` (every
`Repo` function takes it, e.g. `Repo.insert!(note, sync: true)` or
`Repo.transaction(fun, sync: true)`), set `durability: :sync` in the `:s3`
config for all commits, or call `Ecto.Adapters.Sediment.s3_flush(S3Demo.Repo)`
before a moment that matters. A clean shutdown uploads what is pending too
(for up to `:close_timeout_ms`, 10 s by default).

`mix demo.show` and `mix demo.write` keep working on the restored copy, and
you can repeat the kill/wipe/restore cycle as often as you like.

## 4. Take a copy (point-in-time restore)

Restore the database from S3 into a standalone file, without stopping the
writer or touching its lease:

```sh
mix ecto.sediment.s3.restore -r S3Demo.Repo -o /tmp/demo-copy.db
```

The task never replaces a file; to run it again, `rm /tmp/demo-copy.db*` first.
The copy stays encrypted with the same key.

With `retain_epochs: n` in the `:s3` config, `--at 2026-09-30T08:00:00Z`
restores the state as of that moment instead of the latest one.

## 5. Run it as a release

The configuration lives in `config/runtime.exs`, so a release reads the
environment variables when it starts:

```sh
MIX_ENV=prod mix release
export DATABASE_PATH=/tmp/s3_demo_release/demo.db   # any empty directory
_build/prod/rel/s3_demo/bin/s3_demo eval "S3Demo.Release.migrate()"
_build/prod/rel/s3_demo/bin/s3_demo eval "S3Demo.Release.show()"
```

The release restores the same database from S3 into the new directory. `S3Demo.Release` follows the release section of
ecto_sediment's S3 guide.

## How it works

`config/runtime.exs` configures the repo with an `:s3` option:

```elixir
config :s3_demo, S3Demo.Repo,
  database: Path.expand("../data/demo.db", __DIR__),
  encryption: [cipher: "aegis256", key: System.get_env("DATABASE_ENCRYPTION_KEY")],
  s3: [bucket: "s3-demo", prefix: "demo", endpoint: "http://127.0.0.1:8333", owner: "s3-demo", ...]
```

* S3 databases are encrypted by default: a repo with `:s3` needs `:encryption`
  with a key, or `encryption: false` to store the database unencrypted.

* One writer at a time: the repo holds a lease on `<prefix>/lease.json`.
  The fixed `owner` lets a restarted or crashed node take its own lease back
  immediately. A node with another owner is refused until the lease is
  released (on clean shutdown) or expires (30 s by default after a crash).
* `Ecto.Adapters.Sediment.checkpoint(S3Demo.Repo)` uploads a snapshot (only the
  changed segments), which keeps restores fast. Turso also checkpoints automatically.
* See the `Ecto.Adapters.Sediment` docs ("S3-backed databases") and
  `Sediment.S3` for all options.

## Automated walkthrough

`./walkthrough.sh` runs steps 2 and 3 with a fresh prefix and checks that
every durable commit was restored, with no gaps.

## Start over

The data lives in S3 under the prefix, so deleting `data/` never starts over
(`mix setup` then reports "created" but restores the existing database). Use
a new prefix instead, and keep it exported for the following commands:

```sh
export S3_PREFIX=demo2
mix setup
```

or delete the `demo/` prefix in the bucket.
