defmodule Ecto.Adapters.SedimentConnTest do
  use ExUnit.Case

  alias Ecto.Adapters.Sediment

  @uuid_regex ~r/^[[:xdigit:]]{8}\b-[[:xdigit:]]{4}\b-[[:xdigit:]]{4}\b-[[:xdigit:]]{4}\b-[[:xdigit:]]{12}$/

  setup do
    original_binary_id_type =
      Application.get_env(:ecto_sediment, :binary_id_type, :string)

    on_exit(fn ->
      Application.put_env(:ecto_sediment, :binary_id_type, original_binary_id_type)
    end)
  end

  describe ".storage_up/1" do
    test "create database" do
      opts = [database: Temp.path!()]

      assert Sediment.storage_up(opts) == :ok
      assert File.exists?(opts[:database])

      File.rm(opts[:database])
    end

    test "does not fail on second call" do
      opts = [database: Temp.path!()]

      assert Sediment.storage_up(opts) == :ok
      assert File.exists?(opts[:database])
      assert Sediment.storage_up(opts) == {:error, :already_up}

      File.rm(opts[:database])
    end

    test "fails with helpful error message if no database specified" do
      assert_raise(
        ArgumentError,
        """
        No SQLite database path specified. Please check the configuration for your Repo.
        Your config/*.exs file should have something like this in it:

          config :my_app, MyApp.Repo,
            adapter: Ecto.Adapters.Sediment,
            database: "/path/to/sqlite/database"
        """,
        fn -> Sediment.storage_up(mumble: "no database here") == :ok end
      )
    end

    test "can create an in memory database" do
      assert Sediment.storage_up(database: ":memory:", pool_size: 1) == :ok
    end

    test "fails if in memory database does not have a pool size of 1" do
      assert_raise(
        ArgumentError,
        """
        In memory databases must have a pool_size of 1
        """,
        fn -> Sediment.storage_up(database: ":memory:", pool_size: 2) end
      )
    end
  end

  describe ".storage_down/2" do
    test "storage down (twice)" do
      opts = [database: Temp.path!()]

      assert Sediment.storage_up(opts) == :ok
      assert Sediment.storage_down(opts) == :ok
      refute File.exists?(opts[:database])
      assert Sediment.storage_down(opts) == {:error, :already_down}

      File.rm(opts[:database])
    end

    test "removes the MVCC log" do
      dir = Temp.mkdir!()
      opts = [database: Path.join(dir, "mvcc.db"), journal_mode: :mvcc]

      assert Sediment.storage_up(opts) == :ok

      assert {_, 0} =
               Sediment.dump_cmd(["CREATE TABLE t (id INTEGER PRIMARY KEY)"], [], opts)

      assert "mvcc.db-log" in File.ls!(dir)
      assert Sediment.storage_down(opts) == :ok
      assert File.ls!(dir) == []
    end
  end

  describe ".autogenerate/1" do
    test ":id must be generated from storage" do
      assert Sediment.autogenerate(:id) == nil
    end

    test ":embed_id is a UUID in string form" do
      assert string_uuid?(Sediment.autogenerate(:embed_id))
    end

    test ":binary_id with type :string is a UUID in string form" do
      Application.put_env(:ecto_sediment, :binary_id_type, :string)
      assert string_uuid?(Sediment.autogenerate(:binary_id))
    end

    test ":binary_id with type :binary is a UUID in binary form" do
      Application.put_env(:ecto_sediment, :binary_id_type, :binary)
      assert binary_uuid?(Sediment.autogenerate(:binary_id))
    end
  end

  describe "dump_cmd/3" do
    test "runs command" do
      opts = [database: Temp.path!()]

      assert Sediment.storage_up(opts) == :ok

      assert {_out, 0} =
               Sediment.dump_cmd(
                 ["CREATE TABLE test (id INTEGER PRIMARY KEY)"],
                 [],
                 opts
               )

      assert {"CREATE TABLE test (id INTEGER PRIMARY KEY);\n", 0} =
               Sediment.dump_cmd([".schema"], [], opts)
    end
  end

  describe "structure_dump/2 and structure_load/2" do
    test "round-trips schema and migration versions" do
      dir = Temp.mkdir!()
      opts = [database: Path.join(dir, "source.db"), dump_path: Path.join(dir, "s.sql")]

      assert Sediment.storage_up(opts) == :ok

      assert {_, 0} =
               Sediment.dump_cmd(
                 [
                   "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, inserted_at TEXT)",
                   "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)",
                   "CREATE INDEX posts_title_index ON posts (title)",
                   "INSERT INTO schema_migrations VALUES (20240101000000, 'it''s')"
                 ],
                 [],
                 opts
               )

      assert {:ok, path} = Sediment.structure_dump(dir, opts)
      dump = File.read!(path)
      assert dump =~ "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);\n"
      assert dump =~ "CREATE INDEX posts_title_index ON posts (title);\n"

      assert dump =~
               ~s{INSERT INTO "schema_migrations" VALUES(20240101000000,'it''s');\n}

      target = Keyword.put(opts, :database, Path.join(dir, "target.db"))
      assert {:ok, ^path} = Sediment.structure_load(dir, target)

      assert {"20240101000000|it's\n", 0} =
               Sediment.dump_cmd(["SELECT * FROM schema_migrations"], [], target)

      assert {out, 0} = Sediment.dump_cmd([".schema"], [], target)
      assert out =~ "CREATE INDEX posts_title_index"
    end

    test "dump_cmd supports only SQL and .schema" do
      opts = [database: Temp.path!()]

      assert {"unsupported command: .tables", 1} =
               Sediment.dump_cmd([".tables"], [], opts)
    end

    test "NULLs are dumped as NULL and printed as empty" do
      dir = Temp.mkdir!()
      opts = [database: Path.join(dir, "n.db"), dump_path: Path.join(dir, "n.sql")]

      assert {_, 0} =
               Sediment.dump_cmd(
                 [
                   "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, inserted_at TEXT)",
                   "INSERT INTO schema_migrations VALUES (1, NULL)"
                 ],
                 [],
                 opts
               )

      assert {"1|\n", 0} =
               Sediment.dump_cmd(["SELECT * FROM schema_migrations"], [], opts)

      assert {:ok, path} = Sediment.structure_dump(dir, opts)
      assert File.read!(path) =~ ~s{INSERT INTO "schema_migrations" VALUES(1,NULL);}
    end

    test "structure_load reports a missing file" do
      dir = Temp.mkdir!()

      opts = [
        database: Path.join(dir, "m.db"),
        dump_path: Path.join(dir, "missing.sql")
      ]

      assert {:error, "could not read " <> _} = Sediment.structure_load(dir, opts)
    end

    test "dump_cmd reports errors with a non-zero status" do
      opts = [database: Temp.path!()]
      assert {message, 1} = Sediment.dump_cmd(["SELECT * FROM missing"], [], opts)
      assert message =~ "missing"
    end
  end

  defp string_uuid?(uuid), do: Regex.match?(@uuid_regex, uuid)
  defp binary_uuid?(uuid), do: bit_size(uuid) == 128
end
