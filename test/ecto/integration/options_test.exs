defmodule Ecto.Integration.OptionsTest do
  # Every ecto_sqlite3 connection option, set to a non-default value.
  use ExUnit.Case, async: false

  alias EctoSediment.DynamicRepo, as: Repo

  defp pragma(name) do
    %{rows: [[value]]} = Repo.query!("PRAGMA #{name}")
    value
  end

  test "options turso implements take effect" do
    Repo.start_supervised!(
      database: Temp.path!(),
      journal_mode: :wal,
      temp_store: :file,
      synchronous: :full,
      foreign_keys: :off,
      cache_size: -1234,
      cache_spill: :off,
      busy_timeout: 1234,
      pool_size: 1,
      default_transaction_mode: :immediate
    )

    assert pragma("journal_mode") == "wal"
    assert pragma("temp_store") == 1
    assert pragma("synchronous") == 2
    assert pragma("foreign_keys") == 0
    assert pragma("cache_size") == -1234
    assert pragma("cache_spill") == 0
    assert {:ok, :done} = Repo.transaction(fn -> :done end)
  end

  test "sqlite tuning options turso doesn't implement are accepted" do
    Repo.start_supervised!(
      database: Temp.path!(),
      case_sensitive_like: :on,
      auto_vacuum: :none,
      locking_mode: :normal,
      secure_delete: :on,
      wal_auto_check_point: 500
    )

    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  test "load_extensions and key are rejected" do
    for option <- [load_extensions: ["./ext"], key: "secret"] do
      Repo.start_supervised!(
        [database: Temp.path!(), queue_target: 50, queue_interval: 100] ++ [option]
      )

      assert_raise DBConnection.ConnectionError, fn -> Repo.query!("SELECT 1") end
    end
  end

  describe ":mvcc_checkpoint_threshold" do
    test "defaults to 256 KiB for MVCC repos" do
      Repo.start_supervised!(database: Temp.path!(), journal_mode: :mvcc)
      assert pragma("mvcc_checkpoint_threshold") == 262_144
    end

    test "can be changed, or reset to Turso's default with nil" do
      Repo.start_supervised!(
        database: Temp.path!(),
        journal_mode: :mvcc,
        mvcc_checkpoint_threshold: 1_000_000
      )

      assert pragma("mvcc_checkpoint_threshold") == 1_000_000

      Repo.start_supervised!(
        database: Temp.path!(),
        journal_mode: :mvcc,
        mvcc_checkpoint_threshold: nil
      )

      assert pragma("mvcc_checkpoint_threshold") > 262_144
    end

    test "an explicit custom pragma wins" do
      Repo.start_supervised!(
        database: Temp.path!(),
        journal_mode: :mvcc,
        custom_pragmas: [mvcc_checkpoint_threshold: 4096]
      )

      assert pragma("mvcc_checkpoint_threshold") == 4096
    end

    test "is not set in WAL mode" do
      Repo.start_supervised!(database: Temp.path!())
      assert pragma("journal_mode") == "wal"
    end
  end

  # turso_core 0.8.1 reuses AUTOINCREMENT ids after a WAL database is switched
  # to MVCC, silently overwriting rows: the repo must refuse
  # to connect and leave the data alone.
  test "an existing WAL database with AUTOINCREMENT tables is not switched to :mvcc" do
    db = Temp.path!()
    wal = Repo.start_supervised!(database: db)
    Repo.query!("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)")
    Repo.query!("INSERT INTO posts (title) VALUES ('a'), ('b')")
    Supervisor.stop(wal)

    # A pool of two: the bug hit connections opened after the switch. The
    # connections first try to connect while the repo starts, so the capture
    # starts before it.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        mvcc =
          Repo.start_supervised!(
            database: db,
            journal_mode: :mvcc,
            pool_size: 2,
            queue_target: 50,
            queue_interval: 100
          )

        assert_raise DBConnection.ConnectionError, fn ->
          Repo.query!("INSERT INTO posts (title) VALUES ('c')")
        end

        Supervisor.stop(mvcc)
      end)

    assert log =~ "refusing to switch to MVCC"

    Repo.start_supervised!(database: db)
    assert pragma("journal_mode") == "wal"

    assert Repo.query!("SELECT id, title FROM posts ORDER BY id").rows == [
             [1, "a"],
             [2, "b"]
           ]

    assert %{rows: [[3]]} =
             Repo.query!("INSERT INTO posts (title) VALUES ('c') RETURNING id")
  end
end
