defmodule Ecto.Integration.TursoExtensionsTest do
  use ExUnit.Case, async: false

  alias EctoSediment.DynamicRepo, as: Repo

  @key "b1bbfda4f589dc9daaf004fe21111e00dc00c98237102f5c7002a5669fc76327"

  defp stop_repo(pid), do: Supervisor.stop(pid)

  defp values do
    %{rows: rows} = Repo.query!("SELECT v FROM items ORDER BY v")
    List.flatten(rows)
  end

  describe "BEGIN CONCURRENT" do
    setup do
      Repo.start_supervised!(
        database: Temp.path!(),
        journal_mode: :mvcc,
        default_transaction_mode: :concurrent,
        pool_size: 2
      )

      Repo.query!("CREATE TABLE items (id INTEGER PRIMARY KEY, v INTEGER)")
      Repo.query!("INSERT INTO items (id, v) VALUES (1, 0)")
      :ok
    end

    test "concurrent transactions on different rows both commit" do
      results = run_interleaved(&Repo.query!("INSERT INTO items (v) VALUES (?)", [&1]))
      assert results == [{:ok, :ok}, {:ok, :ok}]
      assert values() == [0, 1, 2]
    end

    test "a write-write conflict rolls back one transaction" do
      results =
        run_interleaved(&Repo.query!("UPDATE items SET v = ? WHERE id = 1", [&1]))

      assert Enum.count(results, &match?({:ok, :ok}, &1)) == 1

      assert Enum.any?(results, fn
               {:error, %Sediment.Error{message: message}} -> message =~ "conflict"
               _ -> false
             end)

      assert [v] = values()
      assert v in [1, 2]
    end

    test "migrations work with default_transaction_mode: :concurrent" do
      defmodule CreateThings do
        use Ecto.Migration

        def change do
          create table(:things) do
            add(:name, :string)
          end

          create(index(:things, [:name]))
        end
      end

      migrate = fn direction ->
        Ecto.Migrator.run(Repo, [{1, CreateThings}], direction,
          all: true,
          log: false,
          dynamic_repo: Repo.get_dynamic_repo()
        )
      end

      assert [1] = migrate.(:up)
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM things")
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM schema_migrations")

      # ordinary transactions stay concurrent
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Repo.query!("INSERT INTO things (name) VALUES ('a')")
                 :ok
               end)

      assert [1] = migrate.(:down)

      assert {:error, %Sediment.Error{message: "no such table: things"}} =
               Repo.query("SELECT * FROM things")
    end

    test "a failing migration is rolled back" do
      defmodule BrokenMigration do
        use Ecto.Migration

        def change do
          create(table(:broken_things))
          execute("INSERT INTO no_such_table VALUES (1)", "")
        end
      end

      repo = Repo.get_dynamic_repo()

      assert_raise Sediment.Error, ~r/no such table/, fn ->
        Ecto.Migrator.up(Repo, 2, BrokenMigration, log: false, dynamic_repo: repo)
      end

      assert %{rows: []} =
               Repo.query!(
                 "SELECT name FROM sqlite_schema WHERE name = 'broken_things'"
               )

      assert Ecto.Migrator.migrated_versions(Repo, dynamic_repo: repo) == []
    end

    test "a migration that writes before its first DDL still needs another mode" do
      defmodule DataFirstMigration do
        use Ecto.Migration

        def up do
          repo().query!("INSERT INTO items (v) VALUES (42)")
          create(table(:later_things))
        end

        def down, do: :ok
      end

      repo = Repo.get_dynamic_repo()

      assert_raise Sediment.Error,
                   ~r/DDL statements require an exclusive transaction/,
                   fn ->
                     Ecto.Migrator.up(Repo, 3, DataFirstMigration,
                       log: false,
                       dynamic_repo: repo
                     )
                   end

      # The data write was rolled back with the migration
      assert values() == [0]
    end

    test "no lost updates when concurrent transactions retry on conflict" do
      repo = Repo.get_dynamic_repo()

      increment = fn ->
        %{rows: [[v]]} = Repo.query!("SELECT v FROM items WHERE id = 1")
        Repo.query!("UPDATE items SET v = ? WHERE id = 1", [v + 1])
      end

      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          for _ <- 1..25, do: {:ok, _} = transaction_with_retry(increment)
        end)
      end)
      |> Task.await_many(60_000)

      assert values() == [100]
    end

    test "the mode can be given per transaction" do
      assert {:ok, :ok} =
               Repo.transaction(
                 fn ->
                   Repo.query!("INSERT INTO items (v) VALUES (5)")
                   :ok
                 end,
                 mode: :concurrent
               )

      assert values() == [0, 5]
    end
  end

  # Opens two transactions at the same time, runs `write` in both and then
  # commits them one after the other.
  defp run_interleaved(write) do
    parent = self()
    repo = Repo.get_dynamic_repo()

    tasks =
      for n <- [1, 2] do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          try do
            Repo.transaction(fn ->
              outcome = attempt(fn -> write.(n) end)
              send(parent, {:written, n})
              receive do: (:commit -> :ok)

              case outcome do
                :ok -> :ok
                {:error, error} -> Repo.rollback(error)
              end
            end)
          rescue
            error -> {:error, error}
          end
        end)
      end

    for n <- [1, 2], do: assert_receive({:written, ^n}, 5_000)

    Enum.map(tasks, fn task ->
      send(task.pid, :commit)
      Task.await(task)
    end)
  end

  # The retry recipe from the README ("Concurrent transactions"), with more
  # attempts: four writers increment one row
  defp transaction_with_retry(fun, attempts \\ 50) do
    Repo.transaction(fun)
  rescue
    error in Sediment.Error ->
      if attempts > 1 and
           error.message =~
             ~r/^(Write-write conflict|Database busy|Database schema changed)/ do
        transaction_with_retry(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp attempt(fun) do
    fun.()
    :ok
  rescue
    error -> {:error, error}
  end

  describe "telemetry" do
    test "Ecto queries emit sediment query events" do
      Repo.start_supervised!(database: Temp.path!(), pool_size: 1)
      test_pid = self()
      handler = "query-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:sediment, :query, :stop],
        fn _event, %{duration: duration}, meta, _ ->
          send(test_pid, {:query, meta.query, duration})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      Repo.query!("SELECT 42")
      assert_receive {:query, "SELECT 42", duration} when is_integer(duration)
    end
  end

  describe "encryption, wrong keys" do
    test "a wrong or missing key fails with a clear error" do
      path = Temp.path!()

      config = [
        database: path,
        pool_size: 1,
        encryption: [cipher: "aegis256", key: @key]
      ]

      pid = Repo.start_supervised!(config)
      Repo.query!("CREATE TABLE items (id INTEGER PRIMARY KEY, v TEXT)")
      Supervisor.stop(pid)

      wrong = [cipher: "aegis256", key: String.duplicate("00", 32)]

      dump = fn opts ->
        Ecto.Adapters.Sediment.dump_cmd([".schema"], [], [database: path] ++ opts)
      end

      assert {"Decryption failed" <> _, 1} = dump.(encryption: wrong)
      # Turso names the cause only while the database is still open in this VM
      # (its registry knows the cipher); a closed encrypted file just doesn't
      # parse. The repo above is stopped, so either may come back.
      assert {message, 1} = dump.([])

      assert message in [
               "Database is encrypted but no encryption options provided",
               "File is not a database"
             ]

      assert {"CREATE TABLE items" <> _, 0} = dump.(encryption: config[:encryption])

      # The error doesn't echo the key's characters.
      assert {:error, message} =
               Ecto.Adapters.Sediment.storage_up(
                 database: Temp.path!(),
                 encryption: [cipher: "aegis256", key: "abc"]
               )

      assert message =~ "must be hex encoded"
    end
  end

  describe "encryption" do
    test "stores data encrypted and needs the key to read it" do
      path = Temp.path!()

      config = [
        database: path,
        pool_size: 1,
        encryption: [cipher: "aegis256", key: @key]
      ]

      assert Ecto.Adapters.Sediment.storage_up(config) == :ok
      pid = Repo.start_supervised!(config)
      Repo.query!("CREATE TABLE items (id INTEGER PRIMARY KEY, v TEXT)")
      Repo.query!("INSERT INTO items (v) VALUES ('hidden')")
      stop_repo(pid)

      refute File.read!(path) =~ "hidden"

      Repo.start_supervised!(config)
      assert values() == ["hidden"]
    end
  end
end
