### insert

Repo.insert!/1 of one changeset (one commit each)

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS) | 4180.9 | 239.2 µs | 131.5 µs | 846.1 µs |
| ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS) | 223.0 | 4.48 ms | 3.91 ms | 10.99 ms |


### insert_parallel

Repo.insert!/1 from 4 processes at once (4 parallel callers)

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS) | 995.5 | 1.0 ms | 215.2 µs | 8.52 ms |
| ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS) | 61.6 | 16.24 ms | 3.77 ms | 111.32 ms |


### insert_all

Repo.insert_all/2 of 100 rows (one statement, one commit)

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS) | 258.0 | 3.88 ms | 2.02 ms | 6.02 ms |
| ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS) | 6.5 | 154.44 ms | 5.84 ms | 5652.15 ms |


### transaction

10 Repo.insert!/1 in one Repo.transaction/1

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS) | 261.1 | 3.83 ms | 1.28 ms | 49.96 ms |
| ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS) | 59.8 | 16.71 ms | 7.19 ms | 97.3 ms |


### all

Repo.all/2 loading 1000 rows into structs

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS) | 207.0 | 4.83 ms | 4.5 ms | 10.28 ms |
| ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS) | 155.8 | 6.42 ms | 5.0 ms | 20.55 ms |


### get

Repo.get/2 by primary key

| Repo | ops/s | average | median | p99 |
| ---- | ----: | ------: | -----: | --: |
| ecto_sediment MVCC+S3, durability: :async (integer primary key, local SeaweedFS) | 16429.4 | 60.9 µs | 50.5 µs | 168.5 µs |
| ecto_sediment MVCC+S3, durability: :sync (integer primary key, local SeaweedFS) | 7641.4 | 130.9 µs | 64.1 µs | 2.53 ms |

