defmodule Ecto.Integration.S3DisasterRecoveryTest do
  # End-to-end recovery of S3-backed repos against the local SeaweedFS gateway.
  # Exclude with --exclude s3.
  use ExUnit.Case, async: false

  import Ecto.Query
  import EctoSediment.S3Helpers
  import ExUnit.CaptureLog

  alias Ecto.Adapters.Sediment
  alias EctoSediment.DynamicRepo, as: Repo
  alias EctoSediment.S3App
  alias EctoSediment.S3App.Post

  @moduletag :s3
  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()
  @moduletag timeout: 120_000

  setup_all do
    :ok = ensure_bucket()
  end

  setup %{tmp_dir: dir, test: test} do
    prefix = unique_prefix("dr")
    config = [s3: s3_opts(prefix), encryption: false, pool_size: 2]

    %{
      prefix: prefix,
      config: config,
      dir: dir,
      node: node_config(dir, "node-#{test}", config)
    }
  end

  # Each "node" is a fresh local directory, as on a replacement machine.
  defp node_config(dir, name, config) do
    node_dir = Path.join(dir, String.replace(name, ~r/\W+/, "_"))
    File.mkdir_p!(node_dir)
    Keyword.put(config, :database, Path.join(node_dir, "app.db"))
  end

  defp fresh_node(%{dir: dir, config: config}, name), do: node_config(dir, name, config)

  defp snapshot do
    Post
    |> order_by(:title)
    |> select([p], {p.title, p.views, p.tag})
    |> Repo.all()
  end

  defp versions do
    Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
  end

  defp write_workload do
    S3App.migrate(Repo, Repo.get_dynamic_repo())

    for i <- 1..20, do: Repo.insert!(%Post{title: "post-#{i}", views: i})

    Repo.transaction(fn ->
      for i <- 21..30,
          do: Repo.insert!(%Post{title: "post-#{i}", views: i, tag: "batch"})
    end)

    Repo.update_all(from(p in Post, where: p.views <= 5),
      set: [tag: "early"],
      inc: [views: 100]
    )

    Repo.delete_all(from(p in Post, where: p.views in [10, 11]))

    {:error, :rolled_back} =
      Repo.transaction(fn ->
        Repo.insert!(%Post{title: "never"})
        Repo.rollback(:rolled_back)
      end)

    :ok
  end

  test "a repo is restored on a fresh node after losing the original", ctx do
    assert Sediment.storage_up(ctx.node) == :ok
    pid = Repo.start_supervised!(ctx.node)
    write_workload()
    expected = snapshot()
    assert Enum.count(expected) == 28
    refute Enum.any?(expected, &match?({"never", _, _}, &1))
    Supervisor.stop(pid)

    File.rm_rf!(Path.dirname(ctx.node[:database]))

    replacement = fresh_node(ctx, "replacement")
    assert Sediment.storage_status(replacement) == :down
    assert Sediment.storage_up(replacement) == :ok
    pid = Repo.start_supervised!(replacement)

    assert snapshot() == expected
    assert versions() == [[1], [2]]
    assert Ecto.Migrator.migrated_versions(Repo) == [1, 2]

    # Constraints and indexes came back too
    assert {:error, changeset} =
             %Post{title: "post-1"}
             |> Ecto.Changeset.change()
             |> Ecto.Changeset.unique_constraint(:title)
             |> Repo.insert()

    assert changeset.errors[:title]

    # The restored node keeps writing to S3, and a later restore sees it
    Repo.insert!(%Post{title: "after-restore", views: 1})
    Supervisor.stop(pid)

    Repo.start_supervised!(fresh_node(ctx, "third"))
    assert snapshot() == Enum.sort(expected ++ [{"after-restore", 1, nil}])
  end

  test "a second repo on the same prefix is refused while the lease is held", ctx do
    pid = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, pid)
    Repo.insert!(%Post{title: "from-a"})

    intruder = ctx |> fresh_node("intruder") |> put_in([:s3, :owner], "intruder")

    assert {:error, message} = Sediment.storage_up(intruder)
    assert message =~ "lease held by ecto-test"

    log =
      capture_log(fn ->
        intruder_pid =
          Repo.start_supervised!(intruder ++ [queue_target: 50, queue_interval: 100])

        assert_raise DBConnection.ConnectionError, fn ->
          Repo.all(Post, timeout: 1_000)
        end

        Supervisor.stop(intruder_pid)
      end)

    assert log =~ "lease held by ecto-test"

    # The holder is unaffected
    Repo.put_dynamic_repo(pid)
    Repo.insert!(%Post{title: "still-a"})

    # Once the holder closes, the other writer can take over and sees its data
    Supervisor.stop(pid)
    Repo.start_supervised!(intruder)
    assert [{"from-a", 0, nil}, {"still-a", 0, nil}] == snapshot()
  end

  test "a waiting writer takes over by itself once the holder stops", ctx do
    holder = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, holder)
    Repo.insert!(%Post{title: "from-holder"})

    standby_node = ctx |> fresh_node("standby") |> put_in([:s3, :owner], "standby")

    capture_log(fn ->
      standby =
        Repo.start_supervised!(standby_node ++ [backoff_min: 100, backoff_max: 500])

      Supervisor.stop(holder)

      Repo.put_dynamic_repo(standby)
      assert wait_until(fn -> match?({:ok, _}, Repo.query("SELECT 1")) end)
    end)

    Repo.insert!(%Post{title: "from-standby"})
    assert [{"from-holder", 0, nil}, {"from-standby", 0, nil}] == snapshot()
  end

  # The deploy recipes in guides/s3.md: a migration on a node without the
  # lease fails and changes nothing; the standby runs pending migrations once
  # it has taken over (migrate_when_connected)
  test "migrations need the lease; a standby migrates once it takes over", ctx do
    holder = Repo.start_supervised!(ctx.node)
    migrate(holder, [{1, S3App.CreatePosts}])
    Repo.insert!(%Post{title: "v1"})

    all = [{1, S3App.CreatePosts}, {2, S3App.AddTag}]
    standby_node = ctx |> fresh_node("standby") |> put_in([:s3, :owner], "standby")

    capture_log(fn ->
      other =
        Repo.start_supervised!(standby_node ++ [queue_target: 50, queue_interval: 100])

      assert_raise DBConnection.ConnectionError, fn -> migrate(other, all) end
      Supervisor.stop(other)
    end)

    Repo.put_dynamic_repo(holder)
    assert versions() == [[1]]

    capture_log(fn ->
      standby =
        Repo.start_supervised!(standby_node ++ [backoff_min: 100, backoff_max: 500])

      task = Task.async(fn -> migrate_when_connected(standby, all) end)
      Supervisor.stop(holder)
      assert [2] = Task.await(task, 30_000)

      Repo.put_dynamic_repo(standby)
    end)

    assert versions() == [[1], [2]]
    Repo.insert!(%Post{title: "v2", tag: "new"})
    assert [{"v1", 0, nil}, {"v2", 0, "new"}] == snapshot()
  end

  defp migrate(pid, migrations) do
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false, dynamic_repo: pid)
  end

  defp migrate_when_connected(pid, migrations) do
    Repo.put_dynamic_repo(pid)

    case Repo.query("SELECT 1") do
      {:ok, _} -> migrate(pid, migrations)
      {:error, _} -> Process.sleep(200) && migrate_when_connected(pid, migrations)
    end
  end

  test "a fenced writer recovers by itself once the other writer stops", ctx do
    first = Repo.start_supervised!(ctx.node ++ [backoff_min: 100, backoff_max: 500])
    S3App.migrate(Repo, first)
    # durable before the second node restores
    Repo.insert!(%Post{title: "first-1"}, sync: true)

    # Same owner on another node: takes the lease over at once, fencing `first`
    second = Repo.start_supervised!(fresh_node(ctx, "second"))
    Repo.insert!(%Post{title: "second-1"})

    Repo.put_dynamic_repo(first)
    test_pid = self()
    handler = "fenced-#{inspect(test_pid)}"

    :telemetry.attach(
      handler,
      [:sediment, :connection, :disconnect],
      fn _event, _measurements, meta, _ ->
        send(test_pid, {:disconnect, meta.reason})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    capture_log(fn ->
      # With durability: :sync the commit fails at once. With async durability
      # it may be accepted locally until the uploader finds the other writer;
      # either way it never becomes durable (see the final assertion)
      try do
        Repo.insert(%Post{title: "rejected"})
      rescue
        error in Elixir.Sediment.Error -> assert error.message =~ "fenced"
      end

      # the driver reports why it dropped the connection
      assert_receive {:disconnect, :fenced}, 10_000

      Supervisor.stop(second)

      assert wait_until(fn ->
               try do
                 Repo.insert!(%Post{title: "first-2"})
               rescue
                 _ -> false
               end
             end)
    end)

    assert Enum.map(snapshot(), &elem(&1, 0)) == ["first-1", "first-2", "second-1"]
  end

  defp wait_until(fun, attempts \\ 300) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && wait_until(fun, attempts - 1)
    end
  end

  test "restores from a checkpoint snapshot plus the log written after it", ctx do
    pid = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, pid)
    for i <- 1..10, do: Repo.insert!(%Post{title: "before-#{i}", views: i})

    before = snapshot(pid)
    assert Sediment.checkpoint(pid) == :ok
    assert snapshot(pid) != before

    for i <- 1..5, do: Repo.insert!(%Post{title: "after-#{i}", views: i})
    Repo.delete_all(from(p in Post, where: p.title == "before-1"))
    expected = snapshot()
    Supervisor.stop(pid)

    Repo.start_supervised!(fresh_node(ctx, "restored"))
    assert snapshot() == expected
    assert Enum.count(expected) == 14
    assert versions() == [[1], [2]]
  end

  test "point-in-time restore into a standalone file", ctx do
    node = Keyword.update!(ctx.node, :s3, &(&1 ++ [retain_epochs: 5]))
    pid = Repo.start_supervised!(node)
    S3App.migrate(Repo, pid)

    # Durable before after_a (a restore at a time sees what was durable then)
    for i <- 1..3, do: Repo.insert!(%Post{title: "a-#{i}"}, sync: true)
    Process.sleep(20)
    after_a = DateTime.utc_now()
    Process.sleep(20)
    assert Sediment.checkpoint(pid) == :ok

    for i <- 1..3, do: Repo.insert!(%Post{title: "b-#{i}"})
    assert Sediment.checkpoint(pid) == :ok
    Repo.insert!(%Post{title: "c-1"}, sync: true)

    titles_in = fn path ->
      Repo.start_supervised!(database: path, pool_size: 1)
      Repo.all(from(p in Post, select: p.title, order_by: p.title))
    end

    # While the writer is still running and holding the lease
    latest = Path.join(ctx.dir, "latest.db")
    assert {:ok, _info} = Sediment.s3_restore(node[:s3], latest, encryption: false)

    as_of_a = Path.join(ctx.dir, "as_of_a.db")

    assert {:ok, _info} =
             Sediment.s3_restore(node[:s3], as_of_a, at: after_a, encryption: false)

    Repo.put_dynamic_repo(pid)
    Repo.insert!(%Post{title: "writer-still-works"})

    assert titles_in.(latest) == ~w(a-1 a-2 a-3 b-1 b-2 b-3 c-1)
    assert titles_in.(as_of_a) == ~w(a-1 a-2 a-3)
  end

  test "a large transaction is stored and restored in one piece", ctx do
    pid = Repo.start_supervised!(ctx.node ++ [timeout: 60_000])
    S3App.migrate(Repo, pid)
    now = NaiveDateTime.utc_now(:second)
    padding = String.duplicate("x", 200)

    rows =
      for i <- 1..3_000,
          do: %{
            title: "bulk-#{i}-#{padding}",
            views: i,
            inserted_at: now,
            updated_at: now
          }

    # About 0.7 MB in a single commit, i.e. one log upload
    {:ok, _} =
      Repo.transaction(
        fn ->
          rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(Post, &1))
        end,
        timeout: 60_000
      )

    Supervisor.stop(pid)

    Repo.start_supervised!(fresh_node(ctx, "restored"))
    assert Repo.aggregate(Post, :count) == 3_000
    assert Repo.aggregate(Post, :sum, :views) == div(3_000 * 3_001, 2)
  end

  test "several S3 repos in one VM (one prefix each) write concurrently and stay isolated",
       ctx do
    tenants =
      for n <- 1..4 do
        prefix = "#{ctx.prefix}-tenant-#{n}"

        node =
          ctx
          |> fresh_node("tenant-#{n}")
          |> Keyword.put(:s3, s3_opts(prefix, "tenant-#{n}"))

        pid = Repo.start_supervised!(node)
        S3App.migrate(Repo, pid)
        {n, node, pid}
      end

    tenants
    |> Task.async_stream(
      fn {n, _node, pid} ->
        Repo.put_dynamic_repo(pid)
        for i <- 1..10, do: Repo.insert!(%Post{title: "t#{n}-#{i}", views: n})
      end,
      timeout: 60_000
    )
    |> Stream.run()

    for {_n, _node, pid} <- tenants, do: Supervisor.stop(pid)

    for {n, node, _pid} <- tenants do
      Repo.start_supervised!(
        Keyword.put(node, :database, Path.join(ctx.dir, "restore-#{n}.db"))
      )

      assert Repo.all(from(p in Post, select: p.views, distinct: true)) == [n]
      assert Repo.aggregate(Post, :count) == 10
    end
  end

  test "FTS indexes and vector columns survive a restore", ctx do
    config = ctx.node ++ [experimental: [:index_method]]
    pid = Repo.start_supervised!(config)

    Repo.query!(
      "CREATE TABLE docs (id INTEGER PRIMARY KEY, title TEXT, embedding F32_BLOB(2))"
    )

    Repo.query!("CREATE INDEX docs_fts ON docs USING fts (title)")

    for {title, vector} <- [{"database design", [1, 0]}, {"cooking pasta", [0, 1]}] do
      {:ok, blob} = Ecto.Adapters.Sediment.Vector.dump(vector)

      Repo.query!("INSERT INTO docs (title, embedding) VALUES (?, ?)", [
        title,
        {:blob, blob}
      ])
    end

    Supervisor.stop(pid)

    Repo.start_supervised!(
      Keyword.put(config, :database, Path.join(ctx.dir, "restored.db"))
    )

    assert %{rows: [["database design"]]} =
             Repo.query!("SELECT title FROM docs WHERE fts_match(title, 'database')")

    {:ok, query} = Ecto.Adapters.Sediment.Vector.dump([0, 1])

    assert %{rows: [["cooking pasta"], ["database design"]]} =
             Repo.query!(
               "SELECT title FROM docs ORDER BY vector_distance_cos(embedding, ?)",
               [{:blob, query}]
             )
  end

  test "structure_dump/2 needs the lease and dumps the S3 database", ctx do
    pid = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, pid)

    dump_node = ctx |> fresh_node("dump") |> put_in([:s3, :owner], "dumper")

    dump_config =
      Keyword.put(dump_node, :dump_path, Path.join(ctx.dir, "structure.sql"))

    # While the app holds the lease: a clear error instead of a hang
    assert {:error, message} = Sediment.structure_dump(ctx.dir, dump_config)
    assert message =~ "lease held by ecto-test"

    # The lease is released asynchronously right after the repo stops
    Supervisor.stop(pid)

    assert wait_until(fn ->
             match?({:ok, _}, Sediment.structure_dump(ctx.dir, dump_config))
           end)

    path = dump_config[:dump_path]
    dump = File.read!(path)
    assert dump =~ ~r{CREATE TABLE "?posts"? }
    assert dump =~ ~s{INSERT INTO "schema_migrations" VALUES(1,}
  end

  test "encrypted S3 repos restore with the repo's key", ctx do
    encryption = [cipher: "aegis256", key: String.duplicate("7a", 32)]
    node = Keyword.put(ctx.node, :encryption, encryption)
    pid = Repo.start_supervised!(node)
    Repo.query!("CREATE TABLE secrets (id INTEGER PRIMARY KEY, v TEXT)")
    Repo.query!("INSERT INTO secrets (v) VALUES ('before snapshot')")
    assert Sediment.checkpoint(pid) == :ok
    # a log frame after the snapshot, durable before the restores below
    Repo.query!("INSERT INTO secrets (v) VALUES ('after snapshot')", [], sync: true)

    Application.put_env(:ecto_sediment, Repo, node)
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)

    values_in = fn path, opts ->
      # standalone files (the app env above has the :s3 options)
      Repo.start_supervised!([database: path, pool_size: 1, s3: nil] ++ opts)
      Repo.query!("SELECT v FROM secrets ORDER BY id").rows |> List.flatten()
    end

    # the helper forwards the repo's :encryption
    helper = Path.join(ctx.dir, "helper.db")
    assert {:ok, _} = Sediment.s3_restore(Repo, helper)
    refute File.read!(helper) =~ "snapshot"

    assert values_in.(helper, encryption: encryption) == [
             "before snapshot",
             "after snapshot"
           ]

    # so does the mix task
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    cli = Path.join(ctx.dir, "cli.db")

    Mix.Tasks.Ecto.Sediment.S3.Restore.run([
      "-r",
      inspect(Repo),
      "-o",
      cli,
      "--no-compile"
    ])

    assert values_in.(cli, encryption: encryption) == [
             "before snapshot",
             "after snapshot"
           ]

    # without the key the log can't be read
    assert {:error, _} = Sediment.s3_restore(node[:s3], Path.join(ctx.dir, "nokey.db"))

    Supervisor.stop(pid)

    # a node with a wrong or no key can't connect, says why, and writes nothing
    wrong_key = [cipher: "aegis256", key: String.duplicate("00", 32)]

    for {name, encryption} <- [wrong: wrong_key, none: nil] do
      log =
        capture_log(fn ->
          # encryption: nil, not a missing key: the app env above has the key
          config =
            Keyword.merge(node,
              database: Path.join(ctx.dir, "#{name}.db"),
              encryption: encryption,
              queue_target: 50,
              queue_interval: 100
            )

          other = Repo.start_supervised!(config)
          assert_raise DBConnection.ConnectionError, fn -> Repo.query!("SELECT 1") end
          Supervisor.stop(other)
        end)

      # Without a key sediment says the prefix is encrypted, not
      # that it is corrupt
      expected =
        if name == :wrong,
          do: ~r/can't be read with the given encryption options/,
          else: ~r/is encrypted|can't be read with the given encryption options/

      assert log =~ expected, "#{name}: #{log}"
      refute log =~ "corrupt", "#{name}: #{log}"
    end

    # a fresh node with the key restores and keeps writing
    fresh = Keyword.put(node, :database, Path.join(ctx.dir, "fresh.db"))
    Repo.start_supervised!(fresh)
    Repo.query!("INSERT INTO secrets (v) VALUES ('on the new node')")

    assert Repo.query!("SELECT count(*) FROM secrets").rows == [[3]]
  end

  test "a node that starts while S3 is unreachable boots, then connects once S3 is back",
       ctx do
    %URI{host: host, port: port} = URI.parse(endpoint())

    proxy =
      start_supervised!(
        {EctoSediment.LatencyProxy, upstream: {String.to_charlist(host), port}}
      )

    node =
      ctx.node
      |> put_in(
        [:s3, :endpoint],
        "http://127.0.0.1:#{EctoSediment.LatencyProxy.port(proxy)}"
      )
      |> Keyword.merge(backoff_min: 100, backoff_max: 500)

    pid = Repo.start_supervised!(node)
    S3App.migrate(Repo, pid)
    Repo.insert!(%Post{title: "before-outage"})
    Supervisor.stop(pid)

    EctoSediment.LatencyProxy.set_down(proxy, true)

    for {name, config} <- [
          {"with its working copy", node},
          {"on a fresh disk",
           Keyword.put(node, :database, fresh_node(ctx, "fresh")[:database])}
        ] do
      capture_log(fn ->
        # The repo (and so the application) starts; queries fail meanwhile
        pid =
          Repo.start_supervised!(config ++ [queue_target: 50, queue_interval: 100])

        assert_raise DBConnection.ConnectionError, fn ->
          Repo.all(Post, timeout: 1_000)
        end

        EctoSediment.LatencyProxy.set_down(proxy, false)
        assert wait_until(fn -> match?({:ok, _}, Repo.query("SELECT 1")) end), name
        assert ["before-outage"] == Repo.all(from(p in Post, select: p.title)), name
        Supervisor.stop(pid)
        EctoSediment.LatencyProxy.set_down(proxy, true)
      end)
    end
  end

  # A node whose :prefix changes but keeps its local file (DATABASE_PATH)
  test "a working copy from another prefix is replaced by that prefix's data, never uploaded or wiped",
       ctx do
    title = fn -> Repo.all(from(p in Post, select: p.title)) end
    on_prefix = fn prefix -> put_in(ctx.node, [:s3, :prefix], prefix) end

    pid = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, pid)
    Repo.insert!(%Post{title: "from-a"})
    Supervisor.stop(pid)

    b = unique_prefix("dr-b")
    pid = Repo.start_supervised!(ctx |> fresh_node("b") |> put_in([:s3, :prefix], b))
    S3App.migrate(Repo, pid)
    Repo.insert!(%Post{title: "from-b"})
    Supervisor.stop(pid)

    # The same local file on an existing other prefix: that prefix's data
    pid = Repo.start_supervised!(on_prefix.(b))
    assert title.() == ["from-b"]
    Supervisor.stop(pid)

    # On an empty prefix: the repo can't connect rather than replace the file
    # with a new, empty database, and nothing of the file is uploaded
    empty = unique_prefix("dr-empty")

    log =
      capture_log(fn ->
        pid =
          Repo.start_supervised!(
            on_prefix.(empty) ++ [queue_target: 50, queue_interval: 100]
          )

        assert_raise DBConnection.ConnectionError, fn ->
          Repo.all(from(p in Post, select: p.title), timeout: 1_000)
        end

        Supervisor.stop(pid)
      end)

    assert log =~ "refusing to replace the local file"

    # The file still holds prefix b's data
    {:ok, db} = Elixir.Sediment.Engine.open(ctx.node[:database])
    {:ok, stmt} = Elixir.Sediment.Engine.prepare(db, "SELECT title FROM posts")
    assert {:ok, [["from-b"]]} = Elixir.Sediment.Engine.fetch_all(db, stmt)
    :ok = Elixir.Sediment.Engine.release(db, stmt)
    :ok = Elixir.Sediment.Engine.close(db)

    pid =
      Repo.start_supervised!(fresh_node(ctx, "check") |> put_in([:s3, :prefix], empty))

    assert %{rows: []} =
             Repo.query!("SELECT name FROM sqlite_schema WHERE name = 'posts'")

    Supervisor.stop(pid)

    # And the original prefix is untouched
    Repo.start_supervised!(ctx.node)
    assert title.() == ["from-a"]
  end

  test "mix ecto.sediment.s3.import uploads the repo's existing database", ctx do
    # The application ran without :s3 so far
    plain = Keyword.put(ctx.node, :s3, nil)
    pid = Repo.start_supervised!(plain)
    S3App.migrate(Repo, pid)
    for title <- ~w(before-s3 second third), do: Repo.insert!(%Post{title: title})
    # posts.id is AUTOINCREMENT: its sequence stays at 3
    Repo.delete_all(from(p in Post, where: p.title == "third"))
    Supervisor.stop(pid)
    bytes = File.read!(ctx.node[:database])

    Application.put_env(:ecto_sediment, Repo, ctx.node)
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    task =
      &Mix.Tasks.Ecto.Sediment.S3.Import.run(["-r", inspect(Repo), "--no-compile" | &1])

    task.(["--verify", "restore"])
    assert_received {:mix_shell, :info, ["Imported the database into " <> _]}
    assert File.read!(ctx.node[:database]) == bytes

    # The repo starts with :s3 on that file and on any other machine; the
    # next id continues after the sequence, nothing is overwritten
    titles = fn ->
      Repo.all(from(p in Post, select: {p.id, p.title}, order_by: p.id))
    end

    pid = Repo.start_supervised!(ctx.node)
    assert [{1, "before-s3"}, {2, "second"}] == titles.()
    assert %Post{id: 4} = Repo.insert!(%Post{title: "after-s3"})
    Supervisor.stop(pid)
    Repo.start_supervised!(fresh_node(ctx, "other"))
    assert [{1, "before-s3"}, {2, "second"}, {4, "after-s3"}] == titles.()

    assert_raise Mix.Error, ~r/already holds a database/, fn -> task.([]) end
    assert_raise Mix.Error, ~r/--verify must be/, fn -> task.(["--verify", "nope"]) end
  end

  test "mix ecto.sediment.export_sqlite writes a plain SQLite file from S3", ctx do
    pid = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, pid)
    for title <- ~w(one two three), do: Repo.insert!(%Post{title: title}, sync: true)
    Repo.delete_all(from(p in Post, where: p.title == "three"))
    Repo.query!("SELECT 1", [], sync: true)

    Application.put_env(:ecto_sediment, Repo, ctx.node)
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    output = Path.join(ctx.dir, "sqlite.db")

    task =
      &Mix.Tasks.Ecto.Sediment.ExportSqlite.run([
        "-r",
        inspect(Repo),
        "--no-compile" | &1
      ])

    # while the application keeps running: S3 is only read
    task.(["-o", output])
    assert_received {:mix_shell, :info, ["Exported EctoSediment.DynamicRepo to " <> _]}

    assert <<"SQLite format 3", 0, _::binary-size(2), 2, 2, _::binary>> =
             File.read!(output)

    {:ok, db} = Elixir.Sediment.Engine.open(output)

    {:ok, stmt} =
      Elixir.Sediment.Engine.prepare(db, "SELECT title FROM posts ORDER BY id")

    assert {:ok, [["one"], ["two"]]} = Elixir.Sediment.Engine.fetch_all(db, stmt)
    :ok = Elixir.Sediment.Engine.release(db, stmt)

    {:ok, stmt} =
      Elixir.Sediment.Engine.prepare(
        db,
        "SELECT seq FROM sqlite_sequence WHERE name = 'posts'"
      )

    assert {:ok, [[3]]} = Elixir.Sediment.Engine.fetch_all(db, stmt)
    :ok = Elixir.Sediment.Engine.release(db, stmt)
    :ok = Elixir.Sediment.Engine.close(db)

    assert_raise Mix.Error, ~r/export target exists/, fn -> task.(["-o", output]) end
    assert ["one", "two"] == Repo.all(from(p in Post, select: p.title, order_by: p.id))
    Supervisor.stop(pid)
  end

  test "mix ecto.sediment.export_sqlite exports a relative :database with a WAL tail",
       ctx do
    # Ecto's :database is often relative (priv/repo/app.db); its WAL must
    # come along.
    relative = Path.relative_to_cwd(Path.join(ctx.dir, "plain.db"))
    assert Path.type(relative) == :relative
    {:ok, db} = Elixir.Sediment.Engine.open(relative)

    :ok =
      Elixir.Sediment.Engine.execute(
        db,
        "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      )

    :ok = Elixir.Sediment.Engine.execute(db, "INSERT INTO t VALUES (1, 'a'), (2, 'b')")
    assert File.stat!(relative <> "-wal").size > 0

    Application.put_env(:ecto_sediment, Repo, database: relative, pool_size: 1)
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    output = Path.join(ctx.dir, "rel-export.db")

    Mix.Tasks.Ecto.Sediment.ExportSqlite.run([
      "-r",
      inspect(Repo),
      "-o",
      output,
      "--no-compile"
    ])

    assert_received {:mix_shell, :info, ["Exported EctoSediment.DynamicRepo to " <> _]}
    :ok = Elixir.Sediment.Engine.close(db)

    {:ok, copy} = Elixir.Sediment.Engine.open(output)
    {:ok, stmt} = Elixir.Sediment.Engine.prepare(copy, "SELECT count(*) FROM t")
    assert {:ok, [[2]]} = Elixir.Sediment.Engine.fetch_all(copy, stmt)
    :ok = Elixir.Sediment.Engine.release(copy, stmt)
    :ok = Elixir.Sediment.Engine.close(copy)
  end

  test "mix ecto.sediment.s3.restore", ctx do
    pid = Repo.start_supervised!(ctx.node)
    S3App.migrate(Repo, pid)
    # durable before the restore, which runs while this writer keeps running
    Repo.insert!(%Post{title: "from-mix"}, sync: true)

    Application.put_env(:ecto_sediment, Repo, ctx.node)
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    output = Path.join(ctx.dir, "mix.db")

    Mix.Tasks.Ecto.Sediment.S3.Restore.run([
      "-r",
      inspect(Repo),
      "-o",
      output,
      "--no-compile"
    ])

    assert_received {:mix_shell, :info,
                     ["Restored EctoSediment.DynamicRepo into " <> _]}

    # A standalone file (the app env above has the :s3 options)
    Repo.start_supervised!(database: output, pool_size: 1, s3: nil)
    assert ["from-mix"] == Repo.all(from(p in Post, select: p.title))

    assert_raise Mix.Error, ~r/needs --output/, fn ->
      Mix.Tasks.Ecto.Sediment.S3.Restore.run(["-r", inspect(Repo)])
    end

    # Never over an existing file: an earlier copy, or the running repo's own
    # working copy
    for existing <- [output, ctx.node[:database]] do
      assert_raise Mix.Error,
                   ~r/restore target exists: #{Regex.escape(existing)}/,
                   fn ->
                     Mix.Tasks.Ecto.Sediment.S3.Restore.run([
                       "-r",
                       inspect(Repo),
                       "-o",
                       existing
                     ])
                   end
    end

    Repo.put_dynamic_repo(pid)
    Repo.insert!(%Post{title: "after-refused-restore"})
  end

  # With async durability (the default) a crash may lose the commits made
  # since the last durable one: what survives is a prefix crash-1..k that
  # holds every commit made with sync: true or before a successful s3_flush.
  # With durability: :sync every acknowledged commit survives.
  for {name, extra, sync_every, flush} <- [
        {"async, every 10th insert with sync: true", [durability: :async], 10, false},
        {"async, s3_flush before the crash", [durability: :async], 0, true},
        {"async, frequent automatic checkpoints",
         [durability: :async, checkpoint_threshold: 2_048], 10, false},
        {"durability: :sync", [durability: :sync], 0, false}
      ] do
    @tag s3_extra: extra, sync_every: sync_every, flush: flush
    test "a crash of the writing VM keeps a prefix with every durable commit (#{name})",
         ctx do
      node = Keyword.update!(ctx.node, :s3, &(&1 ++ ctx.s3_extra))
      config_path = Path.join(ctx.dir, "crash_config.term")
      File.write!(config_path, :erlang.term_to_binary(node))

      Repo.start_supervised!(node) |> then(&S3App.migrate(Repo, &1))
      Supervisor.stop(Repo.get_dynamic_repo())

      {output, 0} = run_crash_writer(config_path, 40, ctx.sync_every, ctx.flush)

      acknowledged =
        Regex.scan(~r/^committed(?:-sync)? (\d+)$/m, output, capture: :all_but_first)

      assert Enum.count(acknowledged) == 40, output
      assert output =~ "in transaction"

      synced =
        Regex.scan(~r/^committed-sync (\d+)$/m, output, capture: :all_but_first)
        |> Enum.map(fn [i] -> String.to_integer(i) end)

      durable_up_to =
        cond do
          ctx.s3_extra[:durability] == :sync -> 40
          ctx.flush -> if output =~ ~r/^flushed$/m, do: 40, else: flunk(output)
          true -> Enum.max(synced, fn -> 0 end)
        end

      # Automatic checkpoints moved the database through several epochs
      if ctx.s3_extra[:checkpoint_threshold] && can_list?() do
        assert Enum.any?(list_objects(ctx.prefix), &(&1 =~ "/snapshots/"))
      end

      # The crashed VM never released its lease; the same owner takes it over
      Repo.start_supervised!(fresh_node(ctx, "after-crash"))
      titles = Repo.all(from(p in Post, select: p.title))
      k = length(titles)

      assert Enum.sort(titles) == Enum.sort(for i <- 1..k//1, do: "crash-#{i}"),
             "not a prefix of the commits: #{inspect(titles)}"

      assert k >= durable_up_to,
             "lost durable commits: #{k} restored, #{durable_up_to} durable"
    end
  end

  defp run_crash_writer(config_path, count, sync_every, flush) do
    System.cmd(
      "mix",
      [
        "run",
        "--no-compile",
        "--no-deps-check",
        "--no-start",
        crash_writer(),
        config_path,
        to_string(count),
        to_string(sync_every),
        if(flush, do: "flush", else: "no-flush")
      ],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp crash_writer do
    Path.expand("../../support/scripts/s3_crash_writer.exs", __DIR__)
  end
end
