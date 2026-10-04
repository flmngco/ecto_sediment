# Benchmark results

ecto_sediment 0.1.0 (turso_core 0.8.1, sediment as of 2026-09-30 05:15,
after its write-path work) compared with ecto_sqlite3 0.25.0
(exqlite 0.41.0), run with `mix run run.exs` in this directory. Earlier runs
are kept for comparison: `results/2026-09-29.md` (before the driver's
statement cache and the MVCC checkpoint default) and `results/2026-09-30.md`
(before the write-path work).

**Machine:** AMD Ryzen 5 3600 (8 vCPUs available), 23 GB RAM, Linux, Elixir
1.20.1 / OTP 29, local SSD. The machine was shared with other jobs (load
average 12-19 during the run), so absolute numbers are noisy and averages
(`ops/s`) are skewed by outliers; compare medians within a table.

**Repos** (pool_size 5, each adapter's defaults otherwise):

| Label | Configuration |
| ----- | ------------- |
| ecto_sqlite3 WAL (sync=NORMAL) | `journal_mode: :wal` (ecto_sqlite3 defaults) |
| ecto_sqlite3 WAL (sync=FULL) | plus `synchronous: :full` (fsync on every commit) |
| ecto_sediment WAL | `journal_mode: :wal` (ecto_sediment defaults) |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | `journal_mode: :mvcc, mvcc_checkpoint_threshold: nil` (~4 MB of log between checkpoints) |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | `journal_mode: :mvcc` |
| ecto_sediment MVCC (integer primary key) | plus `migration_primary_key: [type: :integer]` (no `AUTOINCREMENT`) |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | `s3: [durability: :sync, ...]` against SeaweedFS on localhost, `AUTOINCREMENT` keys; every commit is one S3 PUT + HEAD |

The S3 row in the tables below is from before async durability became the
default. The bench now has two S3 repos with integer primary keys,
`durability: :async` (the default) and `durability: :sync`; they are compared
in "S3 durability: async vs sync".

All repos use the same `users` table (created by a migration, so with
`INTEGER PRIMARY KEY AUTOINCREMENT` except in the integer-primary-key
variant). The benchmarks run one after another against the same databases,
so the tables grow during the run.

## Summary

Medians, this run:

* **Reads.** Point lookups (`Repo.get/2`): 50 µs on ecto_sediment WAL against 65 µs
  on ecto_sqlite3. Loading 1,000 rows into structs: 4.1 ms against 7.6 ms.
* **Writes, WAL.** Single-row inserts: 140 µs against 104 µs (ecto_sqlite3
  with `synchronous: :normal`). `insert_all` of 100 rows: 2.8 ms against
  2.3 ms. Ten inserts in one transaction: 0.77 ms against 1.14 ms.
* **MVCC.** With integer primary keys MVCC is the fastest mode for writes
  (85 µs per insert, 140 µs with 4 parallel writers). `AUTOINCREMENT` tables
  are much slower in MVCC (turso_core's hot `sqlite_sequence` row): use
  `migration_primary_key: [type: :integer]` for MVCC repos. turso_core's own
  checkpoint threshold (~4 MB of log) slows writes down a lot more; ecto_sediment
  (via sediment) defaults to 256 KiB.
* **S3.** With the default `durability: :async`, S3 is out of the commit
  path: single inserts take 0.13 ms and 100-row `insert_all` 2.0 ms against a
  local SeaweedFS, about the speed of local MVCC (see "S3 durability: async
  vs sync"). With `durability: :sync` every commit waits for a PUT plus a
  HEAD: about 4-5 ms locally, faster than ecto_sqlite3 with
  `synchronous: :full` on this disk; against real S3 expect tens of commits
  per second (see the S3 guide for latency measurements and group commit).
  Reads are unaffected by S3 in both modes.
* Since the previous run, the driver's write-path work made pooled writes
  about 2x faster and point lookups about 3x faster (compare
  `results/2026-09-30.md`).

No operation failed during this run (the bench counts and reports errors
instead of aborting).

## S3 durability: async vs sync

A later run (sediment as of 2026-09-30, `BENCH_REPOS=S3 mix run run.exs`,
raw output in `results/2026-09-30-s3-durability.md`) compares the two S3
durability modes. Medians:

| Benchmark | `durability: :sync` | `durability: :async` |
| --------- | ------------------- | -------------------- |
| `Repo.insert!/1` (one commit each) | 3.91 ms | 0.13 ms |
| `Repo.insert!/1` from 4 processes | 3.77 ms | 0.22 ms |
| `Repo.insert_all/2`, 100 rows | 5.84 ms (p99 5.6 s: an S3 stall) | 2.02 ms |
| 10 inserts in one transaction | 7.19 ms | 1.28 ms |
| `Repo.all/2`, 1,000 rows | 4.50 ms | 5.00 ms |
| `Repo.get/2` | 64 µs | 51 µs |

With async durability S3 is out of the commit path: writes run at about the
speed of a local MVCC database, and reads are unaffected in both modes. The
tables above use integer primary keys. With `AUTOINCREMENT` keys (a first run
without `migration_primary_key`), async gained little: single inserts 1.7 ms
against 5.6 ms, but `insert_all` (258 ms against 211 ms) and transactions
(59 ms against 51 ms) were no faster than sync. That time is turso_core's
`AUTOINCREMENT` handling in MVCC (its hot `sqlite_sequence` row), which costs
as much without S3; the difference between the two modes there is within this
run's noise. Use integer primary keys for S3 repos.

## Results

### insert

Repo.insert!/1 of one changeset (one commit each)

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC (integer primary key) | 8733.3 | 114.5 µs | 85.2 µs | 225.8 µs |
| ecto_sqlite3 WAL (sync=NORMAL) | 6534.6 | 153.0 µs | 103.6 µs | 309.2 µs |
| ecto_sediment WAL | 4934.6 | 202.7 µs | 139.5 µs | 786.6 µs |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | 3580.3 | 279.3 µs | 209.6 µs | 1.04 ms |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | 667.9 | 1.5 ms | 1.01 ms | 5.6 ms |
| ecto_sqlite3 WAL (sync=FULL) | 204.8 | 4.88 ms | 3.66 ms | 14.36 ms |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | 175.4 | 5.7 ms | 4.83 ms | 18.89 ms |


### insert_parallel

Repo.insert!/1 from 4 processes at once (4 parallel callers)

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC (integer primary key) | 1509.0 | 662.7 µs | 140.8 µs | 8.42 ms |
| ecto_sqlite3 WAL (sync=NORMAL) | 954.5 | 1.05 ms | 237.3 µs | 18.27 ms |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | 765.0 | 1.31 ms | 240.4 µs | 20.31 ms |
| ecto_sediment WAL | 539.2 | 1.85 ms | 608.2 µs | 18.1 ms |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | 85.7 | 11.67 ms | 3.28 ms | 151.93 ms |
| ecto_sqlite3 WAL (sync=FULL) | 35.8 | 27.93 ms | 6.47 ms | 836.46 ms |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | 33.7 | 29.63 ms | 6.48 ms | 947.04 ms |

Errors during the run:

* ecto_sediment MVCC (turso_core default checkpoint threshold): 3 × `Database busy`

### insert_all

Repo.insert_all/2 of 100 rows (one statement, one commit)

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment WAL | 220.0 | 4.54 ms | 2.75 ms | 26.91 ms |
| ecto_sqlite3 WAL (sync=NORMAL) | 114.7 | 8.72 ms | 2.33 ms | 64.77 ms |
| ecto_sediment MVCC (integer primary key) | 80.0 | 12.51 ms | 5.37 ms | 99.2 ms |
| ecto_sqlite3 WAL (sync=FULL) | 34.1 | 29.34 ms | 27.54 ms | 86.39 ms |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | 20.8 | 48.01 ms | 34.12 ms | 184.91 ms |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | 3.7 | 272.64 ms | 241.09 ms | 568.63 ms |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | 1.0 | 967.32 ms | 955.58 ms | 1155.39 ms |


### transaction

10 Repo.insert!/1 in one Repo.transaction/1

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment WAL | 1113.5 | 898.1 µs | 764.9 µs | 3.27 ms |
| ecto_sediment MVCC (integer primary key) | 912.9 | 1.1 ms | 810.1 µs | 4.88 ms |
| ecto_sqlite3 WAL (sync=NORMAL) | 658.3 | 1.52 ms | 1.14 ms | 10.06 ms |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | 311.2 | 3.21 ms | 2.72 ms | 14.46 ms |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | 27.0 | 37.07 ms | 37.39 ms | 69.66 ms |
| ecto_sqlite3 WAL (sync=FULL) | 21.6 | 46.36 ms | 18.12 ms | 323.8 ms |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | 18.7 | 53.54 ms | 56.51 ms | 82.72 ms |


### all

Repo.all/2 loading 1000 rows into structs

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment WAL | 232.1 | 4.31 ms | 4.1 ms | 9.4 ms |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | 184.8 | 5.41 ms | 5.01 ms | 13.39 ms |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | 174.4 | 5.73 ms | 5.3 ms | 13.69 ms |
| ecto_sqlite3 WAL (sync=FULL) | 144.6 | 6.91 ms | 5.7 ms | 34.99 ms |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | 138.0 | 7.25 ms | 5.68 ms | 22.03 ms |
| ecto_sediment MVCC (integer primary key) | 120.4 | 8.31 ms | 6.12 ms | 27.01 ms |
| ecto_sqlite3 WAL (sync=NORMAL) | 84.8 | 11.79 ms | 7.61 ms | 87.32 ms |


### get

Repo.get/2 by primary key

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment WAL | 15800.6 | 63.3 µs | 50.0 µs | 203.5 µs |
| ecto_sqlite3 WAL (sync=FULL) | 13618.1 | 73.4 µs | 60.8 µs | 216.8 µs |
| ecto_sqlite3 WAL (sync=NORMAL) | 12081.7 | 82.8 µs | 65.1 µs | 262.6 µs |
| ecto_sediment MVCC (256 KiB checkpoint threshold, ecto_sediment default) | 12012.6 | 83.2 µs | 62.2 µs | 256.5 µs |
| ecto_sediment MVCC+S3, durability: :sync (local SeaweedFS) | 9030.3 | 110.7 µs | 61.2 µs | 1.01 ms |
| ecto_sediment MVCC (turso_core default checkpoint threshold) | 5806.9 | 172.2 µs | 100.0 µs | 3.33 ms |
| ecto_sediment MVCC (integer primary key) | 5487.3 | 182.2 µs | 103.0 µs | 3.61 ms |


## Reproducing

```sh
cd bench
mix deps.get
mix run run.exs                       # all benchmarks, 5 s each, writes results/latest.md
BENCH=insert BENCH_TIME=2 mix run run.exs
BENCH_REPOS=Sediment mix run run.exs  # only repos whose module name contains "Sediment"
mix run mvcc_log_growth.exs           # MVCC write latency vs un-checkpointed log
mix run multi_tenant.exs local 1000   # resources of 1,000 open tenant repos (also: s3), see guides/multi_tenant.md
```

The MVCC+S3 repo needs an S3-compatible server at `http://127.0.0.1:8333`
(`S3_ENDPOINT`, `S3_BUCKET` to change).
