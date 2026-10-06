defmodule Ecto.Integration.S3Test do
  # Runs against the local SeaweedFS S3 gateway; exclude with --exclude s3
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Sediment
  alias EctoSediment.DynamicRepo, as: Repo
  alias EctoSediment.Schemas.User

  @moduletag :s3
  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()

  import EctoSediment.S3Helpers

  setup_all do
    :ok = ensure_bucket()
  end

  setup %{tmp_dir: dir} do
    s3 = s3_opts(unique_prefix("s3"))

    config = [
      database: Path.join(dir, "app.db"),
      s3: s3,
      encryption: false,
      pool_size: 2
    ]

    %{config: config, dir: dir}
  end

  test "data survives losing the local database", %{config: config, dir: dir} do
    assert Sediment.storage_up(config) == :ok

    pid = Repo.start_supervised!(config)

    Repo.query!("""
    CREATE TABLE users (
      id INTEGER PRIMARY KEY, name TEXT, inserted_at TEXT, updated_at TEXT
    )
    """)

    Repo.insert!(%User{name: "alice"})
    Repo.transaction(fn -> Repo.insert!(%User{name: "bob"}) end)
    Supervisor.stop(pid)

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    assert Sediment.storage_status(config) == :down

    Repo.start_supervised!(config)
    assert ["alice", "bob"] == Repo.all(User) |> Enum.map(& &1.name) |> Enum.sort()
    assert Sediment.storage_status(config) == :up
  end

  test "adding :s3 to a repo with an existing database refuses to start over it", %{
    config: config
  } do
    plain = Keyword.delete(config, :s3)
    pid = Repo.start_supervised!(plain)
    Repo.query!("CREATE TABLE t (v)")
    Repo.query!("INSERT INTO t VALUES (1)")
    Supervisor.stop(pid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = Repo.start_supervised!(config ++ [queue_target: 50, queue_interval: 100])

        assert_raise DBConnection.ConnectionError, fn ->
          Repo.query!("SELECT v FROM t", [], timeout: 1_000)
        end

        Supervisor.stop(pid)
      end)

    assert log =~ "refusing to replace the local file"

    Repo.start_supervised!(plain)
    assert %{rows: [[1]]} = Repo.query!("SELECT v FROM t")
  end

  test "checkpoint/2 uploads a snapshot", %{config: config} do
    pid = Repo.start_supervised!(config)
    Repo.query!("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    Repo.query!("INSERT INTO t VALUES (1)")

    before = snapshot(pid)
    assert Sediment.checkpoint(pid) == :ok
    assert snapshot(pid) != before
  end

  test "s3_snapshot/1 starts a new epoch; a repo without S3 gets an error",
       %{config: config, dir: dir} do
    pid = Repo.start_supervised!(config)
    Repo.query!("CREATE TABLE t (id INTEGER PRIMARY KEY)")

    epoch = fn ->
      {:ok, info} = Sediment.s3_info(pid)
      info.epoch
    end

    first = epoch.()
    assert Sediment.s3_snapshot(pid) == :ok
    second = epoch.()
    assert second != first
    # the repo module (its current dynamic repo) too
    assert Sediment.s3_snapshot(Repo) == :ok
    assert epoch.() not in [first, second]

    Repo.start_supervised!(database: Path.join(dir, "local.db"), pool_size: 1)
    assert Sediment.s3_snapshot(Repo) == {:error, "not an s3 database"}
  end

  # An open transaction on another connection: checkpoint/2 waits for it,
  # automatic checkpoints are postponed until it ends (writes don't wait)
  test "checkpoints and open transactions", %{config: config} do
    config =
      config
      |> Keyword.put(:pool_size, 3)
      |> put_in([:s3, :checkpoint_threshold], 16_384)

    pid = Repo.start_supervised!(config)
    Repo.query!("CREATE TABLE t (v)")

    epoch = fn ->
      {:ok, info} = Sediment.s3_info(pid)
      info.epoch
    end

    write = fn n ->
      for _ <- 1..n, do: Repo.query!("INSERT INTO t VALUES (randomblob(1000))")
    end

    parent = self()

    reader =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)

        Repo.transaction(fn ->
          Repo.query!("SELECT count(*) FROM t")
          send(parent, :reading)
          receive do: (:done -> Repo.query!("SELECT count(*) FROM t").rows)
        end)
      end)

    assert_receive :reading, 5_000
    first = epoch.()
    write.(40)
    assert epoch.() == first

    spawn(fn ->
      Process.sleep(1_000)
      send(reader.pid, :done)
    end)

    {us, :ok} = :timer.tc(fn -> Sediment.checkpoint(pid) end)
    assert us >= 900_000
    # The reader kept its snapshot
    assert {:ok, [[0]]} = Task.await(reader)
    second = epoch.()
    assert second != first

    # Without open transactions, automatic checkpoints run again
    write.(40)
    assert epoch.() != second
  end

  test "a replica repo follows the writer with s3_refresh/1", %{
    config: config,
    dir: dir
  } do
    writer = Repo.start_supervised!(config)
    Repo.query!("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    # A replica sees what is durable in S3
    Repo.query!("INSERT INTO t VALUES (1)", [], sync: true)
    assert {:ok, %{owner: "ecto-test"}} = Sediment.s3_info(writer)

    replica_s3 = Keyword.merge(config[:s3], owner: "reader", mode: :replica)

    replica =
      Repo.start_supervised!(
        database: Path.join(dir, "replica.db"),
        s3: replica_s3,
        encryption: false,
        pool_size: 2
      )

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM t")

    Repo.put_dynamic_repo(writer)
    Repo.query!("INSERT INTO t VALUES (2)", [], sync: true)

    Repo.put_dynamic_repo(replica)
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM t")
    assert {:ok, %{mode: :replica}} = Sediment.s3_refresh(replica)
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM t")
    assert {:ok, %{mode: :replica}} = Sediment.s3_info(Repo)

    assert {:error, %{message: "attempt to write a readonly database"}} =
             Repo.query("INSERT INTO t VALUES (3)")

    assert_raise Elixir.Sediment.Error, ~r/readonly database/, fn ->
      Repo.transaction(fn -> Repo.query!("INSERT INTO t VALUES (4)") end)
    end

    # and the replica stays usable
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM t")
  end

  test "s3_refresh/1 brings every pooled replica connection up to date, across checkpoints",
       %{config: config, dir: dir} do
    writer = Repo.start_supervised!(config)
    Repo.query!("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    Repo.query!("INSERT INTO t VALUES (1)", [], sync: true)

    replica_config = [
      database: Path.join(dir, "replica.db"),
      s3: Keyword.merge(config[:s3], owner: "reader", mode: :replica),
      encryption: false,
      pool_size: 4
    ]

    replica = Repo.start_supervised!(replica_config)

    counts = fn ->
      1..16
      |> Task.async_stream(fn _ ->
        Repo.put_dynamic_repo(replica)

        # Hold the connection a moment so the reads spread over the pool
        Repo.checkout(fn ->
          Process.sleep(20)
          Repo.query!("SELECT count(*) FROM t").rows
        end)
      end)
      |> Enum.map(fn {:ok, [[n]]} -> n end)
      |> Enum.uniq()
    end

    assert counts.() == [1]

    Repo.put_dynamic_repo(writer)
    for i <- 2..20, do: Repo.query!("INSERT INTO t VALUES (?)", [i])
    assert Sediment.checkpoint(writer) == :ok
    Repo.query!("INSERT INTO t VALUES (21)", [], sync: true)

    # Without a refresh a connection keeps the state it restored when it
    # connected (one that reconnects starts from a newer state)
    assert Enum.all?(counts.(), &(&1 in [1, 20, 21]))
    assert {:ok, %{mode: :replica}} = Sediment.s3_refresh(replica)
    assert counts.() == [21]

    # A replica started later sees the same state
    Repo.put_dynamic_repo(replica)
    Supervisor.stop(replica)

    replica =
      Repo.start_supervised!(
        Keyword.put(replica_config, :database, Path.join(dir, "r2.db"))
      )

    Repo.put_dynamic_repo(replica)
    assert %{rows: [[21]]} = Repo.query!("SELECT count(*) FROM t")
  end

  # Async durability (the default) is covered by s3_durability_test.exs
  test "with durability: :sync commits wait for S3, reads don't", %{config: config} do
    %URI{host: host, port: port} = URI.parse(endpoint())

    proxy =
      start_supervised!(
        {EctoSediment.LatencyProxy, upstream: {String.to_charlist(host), port}}
      )

    s3 =
      Keyword.merge(config[:s3],
        endpoint: "http://127.0.0.1:#{EctoSediment.LatencyProxy.port(proxy)}",
        durability: :sync
      )

    Repo.start_supervised!(Keyword.put(config, :s3, s3))
    Repo.query!("CREATE TABLE t (v TEXT)")

    time = fn fun -> fun |> :timer.tc() |> elem(0) |> div(1000) end

    EctoSediment.LatencyProxy.set_delay(proxy, 150)
    # A commit is one PUT plus one HEAD, each delayed by at least 150 ms
    slow = time.(fn -> Repo.query!("INSERT INTO t VALUES ('slow')") end)
    assert slow >= 300
    assert time.(fn -> Repo.query!("SELECT count(*) FROM t") end) < 150

    EctoSediment.LatencyProxy.set_delay(proxy, 0)
    assert time.(fn -> Repo.query!("INSERT INTO t VALUES ('fast')") end) < slow - 150
  end

  test "a query timeout cancels a commit waiting for S3 (durability: :sync)", %{
    config: config
  } do
    %URI{host: host, port: port} = URI.parse(endpoint())

    proxy =
      start_supervised!(
        {EctoSediment.LatencyProxy, upstream: {String.to_charlist(host), port}}
      )

    s3 =
      Keyword.merge(config[:s3],
        endpoint: "http://127.0.0.1:#{EctoSediment.LatencyProxy.port(proxy)}",
        durability: :sync
      )

    Repo.start_supervised!(
      Keyword.merge(config, s3: s3, backoff_min: 100, backoff_max: 500)
    )

    Repo.query!("CREATE TABLE t (v TEXT)")

    EctoSediment.LatencyProxy.set_delay(proxy, 5_000)

    {time, _} =
      :timer.tc(fn ->
        assert_raise Elixir.Sediment.Error, ~r/cancelled while waiting for S3/, fn ->
          Repo.query!("INSERT INTO t VALUES ('x')", [], timeout: 1_000)
        end
      end)

    assert div(time, 1000) < 3_000
    EctoSediment.LatencyProxy.set_delay(proxy, 0)
  end

  test "busy_timeout defaults to 15 s for S3 repos", %{config: config, dir: dir} do
    Repo.start_supervised!(config)
    assert %{rows: [[15_000]]} = Repo.query!("PRAGMA busy_timeout")

    Repo.start_supervised!(
      Keyword.merge(config, database: Path.join(dir, "other.db"), busy_timeout: 500)
      |> Keyword.update!(:s3, &Keyword.put(&1, :prefix, &1[:prefix] <> "-other"))
    )

    assert %{rows: [[500]]} = Repo.query!("PRAGMA busy_timeout")
  end

  test "storage_down warns that the data in S3 is kept", %{config: config} do
    assert Sediment.storage_up(config) == :ok

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Sediment.storage_down(config) == :ok
      end)

    assert log =~ "the database in S3"
    assert log =~ config[:s3][:prefix]
  end

  test "s3_exists?/1 and s3_destroy/2 take the repo's :s3 configuration", %{
    config: config
  } do
    Application.put_env(:ecto_sediment, Repo, config)
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)
    refute Sediment.s3_exists?(Repo)

    pid = Repo.start_supervised!(config)
    Repo.query!("CREATE TABLE gone (v TEXT)")
    Repo.query!("INSERT INTO gone VALUES ('x')", [], sync: true)
    assert Sediment.s3_exists?(Repo)
    assert {:error, _} = Sediment.s3_destroy(Repo)
    Supervisor.stop(pid)

    assert {:ok, %{objects: objects}} = Sediment.s3_destroy(Repo)
    assert objects > 0
    refute Sediment.s3_exists?(Repo)
    assert :ok = Sediment.storage_down(config)

    Repo.start_supervised!(config)

    assert %{rows: []} =
             Repo.query!("SELECT name FROM sqlite_master WHERE name = 'gone'")
  end

  test "credentials never show up in logs or errors", %{config: config, dir: dir} do
    secret = "SECRET-#{System.unique_integer([:positive])}"

    s3 =
      Keyword.merge(config[:s3],
        bucket: "ecto-missing-bucket",
        access_key_id: "AKID-#{secret}",
        secret_access_key: secret,
        request_timeout_ms: 1_000,
        max_retries: 0
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid =
          Repo.start_supervised!(
            database: Path.join(dir, "a.db"),
            s3: s3,
            encryption: false,
            pool_size: 1
          )

        {:error, error} = Repo.query("SELECT 1", [], timeout: 1_000)
        refute Exception.message(error) =~ secret

        {:error, message} =
          Sediment.storage_up(
            database: Path.join(dir, "b.db"),
            s3: s3,
            encryption: false
          )

        refute message =~ secret

        {:error, message} =
          Sediment.s3_restore(s3, Path.join(dir, "c.db"), encryption: false)

        refute message =~ secret
        Supervisor.stop(pid)
      end)

    assert log =~ "failed to connect"
    refute log =~ secret
  end

  test "a replica of an empty prefix can't connect", %{config: config, dir: dir} do
    s3 = Keyword.merge(config[:s3], owner: "reader", mode: :replica)

    assert {:error, message} =
             Sediment.storage_up(
               database: Path.join(dir, "r.db"),
               s3: s3,
               encryption: false
             )

    assert message =~ "no database"
  end

  # S3 databases are encrypted unless the repo opts out with `encryption: false`
  test "an S3 repo needs a key or an explicit encryption: false", %{
    config: config,
    dir: dir
  } do
    refuse = fn config ->
      ExUnit.CaptureLog.capture_log(fn ->
        pid = Repo.start_supervised!(config ++ [queue_target: 50, queue_interval: 100])
        assert_raise DBConnection.ConnectionError, fn -> Repo.query!("SELECT 1") end
        Supervisor.stop(pid)
      end)
    end

    implicit = Keyword.delete(config, :encryption)
    assert refuse.(implicit) =~ "encrypted by default"

    # An unencrypted database in S3 must be opened with encryption: false
    assert Sediment.storage_up(config) == :ok

    assert refuse.(Keyword.put(implicit, :database, Path.join(dir, "b.db"))) =~
             "is unencrypted"

    # With a key the data in S3 is encrypted, and a restore needs the key
    key = [cipher: "aegis256", key: String.duplicate("5e", 32)]

    encrypted =
      Keyword.merge(config,
        database: Path.join(dir, "c.db"),
        encryption: key,
        s3: Keyword.update!(config[:s3], :prefix, &(&1 <> "-encrypted"))
      )

    Repo.start_supervised!(encrypted)
    Repo.query!("CREATE TABLE t (v TEXT)")
    Repo.query!("INSERT INTO t VALUES ('secret')", [], sync: true)

    assert {:error, message} =
             Sediment.s3_restore(encrypted[:s3], Path.join(dir, "d.db"),
               encryption: false
             )

    assert message =~ "is encrypted:"

    assert {:ok, _} =
             Sediment.s3_restore(encrypted[:s3], Path.join(dir, "e.db"),
               encryption: key
             )
  end

  test "nil-valued s3 options (from System.get_env/1) are treated as unset", %{
    config: config
  } do
    config = Keyword.update!(config, :s3, &(&1 ++ [session_token: nil, region: nil]))
    assert Sediment.storage_up(config) == :ok
    Repo.start_supervised!(config)
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")

    assert Ecto.Adapters.Sediment.Connection.normalize_opts(
             s3: [bucket: "b", endpoint: nil]
           ) ==
             [s3: [bucket: "b"]]
  end

  test "uses MVCC journal mode by default", %{config: config} do
    Repo.start_supervised!(config)
    assert %{rows: [["mvcc"]]} = Repo.query!("PRAGMA journal_mode")

    # S3 repos keep their own checkpoint schedule, not the MVCC default
    assert %{rows: [[threshold]]} = Repo.query!("PRAGMA mvcc_checkpoint_threshold")
    assert threshold != 262_144
  end
end
