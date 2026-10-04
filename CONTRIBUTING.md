# Contributing to ecto_sediment

Bug reports, fixes and improvements are welcome. ecto_sediment is a port of
[ecto_sqlite3](https://github.com/elixir-sqlite/ecto_sqlite3) to
[Sediment](https://github.com/flmngco/sediment): where the Turso engine behaves
differently from SQLite, the difference is documented in the README
("Differences from ecto_sqlite3"); where it offers more (S3, encryption,
vectors, concurrent transactions), the adapter exposes it as an extension.

## Development setup

You need Elixir 1.18+ (OTP 27+), a Rust toolchain (1.91+, e.g. via `rustup`)
and docker for the S3 tests: a Sediment checkout always builds its NIF from
source.

ecto_sediment depends on Sediment by path. Check out both repositories side by
side:

```sh
git clone https://github.com/flmngco/sediment.git
git clone https://github.com/flmngco/ecto_sediment.git
cd ecto_sediment
mix deps.get
mix compile   # the first compile builds Sediment's NIF and takes a few minutes
```

To use a Sediment checkout somewhere else, set `SEDIMENT_PATH`.

The S3 tests need an S3-compatible server at `http://127.0.0.1:8333` that
accepts unsigned requests. SeaweedFS 4.48 does (newer images refuse them by
default):

```sh
docker run -d --name seaweedfs -p 127.0.0.1:8333:8333 chrislusf/seaweedfs:4.48 server -s3
```

## Running the tests

| Command | What it runs |
| ------- | ------------ |
| `mix test` | The unit tests and the adapter's integration tests (S3 ones included; `--exclude s3` skips those) |
| `SEDIMENT_INTEGRATION=true mix test` | The ecto and ecto_sql integration suites, in WAL mode |
| `mix test.integration` | Those suites in all seven modes: WAL, MVCC, MVCC with `default_transaction_mode: :concurrent`, encrypted, S3, S3 with group commit, encrypted S3 |
| `mix test --only s3_fault` | S3 outages: starts its own SeaweedFS container with docker and pauses it mid-write |
| `mix test --only torture` | S3 crash torture (minutes): writers in a separate VM killed at random points, then the restored state checked (`TORTURE_ROUNDS` sets the rounds) |
| `mix test --only slow` | The Oban cron test, which waits for a minute boundary |
| `mix ci` | What CI requires: compile with warnings as errors, format, `mix test`, `mix test.integration`, `s3_fault`, credo, ex_dna and reach |

The integration suites read these variables: `SEDIMENT_JOURNAL_MODE=mvcc`,
`SEDIMENT_TRANSACTION_MODE=concurrent`, `SEDIMENT_ENCRYPTION_KEY=<64 hex
chars>`, `SEDIMENT_S3=true` and `SEDIMENT_S3_GROUP_COMMIT=true`.

The `:torture` and `:slow` tags are excluded by default and are not part of
`mix ci`; run them when you change the S3 code paths or the Oban integration.

### Other S3 servers

Any S3 server can run the S3 tests: set `S3_TEST_ENDPOINT`, `S3_TEST_BUCKET`,
`S3_TEST_ACCESS_KEY_ID` and `S3_TEST_SECRET_ACCESS_KEY` (the bucket must
exist). The few checks that list objects (with unsigned requests) are skipped then.

## Benchmarks and the demo

`bench/` is a separate Mix project comparing ecto_sediment with ecto_sqlite3
(`cd bench && mix deps.get && mix run run.exs`, see `bench/RESULTS.md`).
`examples/s3_demo` is a runnable S3 walkthrough (see its README); its
`walkthrough.sh` runs it end to end.

## Pull requests

* Run `mix ci` and make sure it passes; CI runs the same on the oldest and
  newest supported Elixir/OTP versions.
* Add or update tests for the change: unit tests for generated SQL,
  integration tests for behaviour against the database.
* Keep behaviour aligned with ecto_sqlite3 unless the Turso engine differs;
  document a difference in the README ("Differences from ecto_sqlite3").
* Update the docs (README, guides, moduledocs) and add a CHANGELOG entry for
  user-visible changes.
* Keep commits focused, with messages that explain why.
