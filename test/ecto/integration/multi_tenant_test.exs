defmodule Ecto.Integration.MultiTenantTest do
  # The patterns of guides/multi_tenant.md, run with the guide's own
  # reference code (evaluated from the guide, so the two can't drift apart).
  use ExUnit.Case, async: false

  import EctoSediment.S3Helpers

  # MyApp.* are defined at run time, from the guide
  @compile {:no_warn_undefined, [MyApp.Tenants, MyApp.Repo]}

  @moduletag :s3
  @moduletag :tmp_dir

  defmodule Migrations.CreateNotes do
    use Ecto.Migration

    def change do
      create table(:notes, primary_key: false) do
        add(:id, :integer, primary_key: true)
        add(:body, :text)
      end
    end
  end

  setup_all do
    :ok = ensure_bucket()

    migrations = Path.join(System.tmp_dir!(), "ecto_sediment_tenant_migrations")
    File.mkdir_p!(migrations)

    File.write!(Path.join(migrations, "1_create_notes.exs"), """
    defmodule MyApp.Repo.Migrations.CreateNotes do
      use Ecto.Migration
      def change, do: Ecto.Integration.MultiTenantTest.Migrations.CreateNotes.change()
    end
    """)

    unless Code.ensure_loaded?(MyApp.Tenants) do
      defmodule Elixir.MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Sediment
      end

      [_, code] =
        Regex.run(~r/evaluates this block -->\n```elixir\n(.*?)\n```/s, guide())

      Code.compile_string(code, "guides/multi_tenant.md")
    end

    %{migrations: migrations}
  end

  defp guide, do: File.read!(Path.expand("../../../guides/multi_tenant.md", __DIR__))

  setup %{tmp_dir: dir, migrations: migrations} do
    base = unique_prefix("tenants")
    keys = :ets.new(:keys, [:public])
    # a tenant moved to another prefix
    prefixes = :ets.new(:prefixes, [:public])

    prefix = fn tenant_id ->
      case :ets.lookup(prefixes, tenant_id) do
        [{_, prefix}] -> prefix
        [] -> "#{base}/#{tenant_id}/"
      end
    end

    # Per-tenant database file, S3 prefix and encryption key
    repo_config = fn tenant_id ->
      key =
        case :ets.lookup(keys, tenant_id) do
          [{_, key}] -> key
          [] -> tap(Sediment.S3.generate_key(), &:ets.insert(keys, {tenant_id, &1}))
        end

      [
        database: Path.join(dir, "#{tenant_id}.db"),
        pool_size: 1,
        encryption: [cipher: "aegis256", key: key],
        s3: s3_opts(prefix.(tenant_id), "node-a")
      ]
    end

    Application.put_env(:my_app, MyApp.Tenants,
      repo: repo_config,
      migrations_path: migrations,
      idle_after: 60_000
    )

    # Started once for the module (it compiles the migrations when it starts);
    # every test uses its own tenants
    unless Process.whereis(MyApp.Tenants) do
      {:ok, pid} = MyApp.Tenants.start_link([])
      Process.unlink(pid)
    end

    %{dir: dir, repo_config: repo_config, prefixes: prefixes, base: base}
  end

  defp insert!(tenant, body) do
    MyApp.Tenants.with_tenant(tenant, fn ->
      MyApp.Repo.query!("INSERT INTO notes (body) VALUES (?)", [body])
    end)
  end

  defp bodies(tenant) do
    MyApp.Tenants.with_tenant(tenant, fn ->
      MyApp.Repo.query!("SELECT body FROM notes ORDER BY id").rows |> List.flatten()
    end)
  end

  test "a tenant's repo starts on first use, migrated; tenants are kept apart" do
    insert!("acme", "a1")
    insert!("globex", "g1")
    insert!("acme", "a2")

    assert bodies("acme") == ["a1", "a2"]
    assert bodies("globex") == ["g1"]

    [{acme, _}] = Registry.lookup(MyApp.Tenants.Registry, "acme")
    [{globex, _}] = Registry.lookup(MyApp.Tenants.Registry, "globex")
    assert acme != globex
  end

  test "concurrent first uses of a tenant start one repo" do
    1..20
    |> Task.async_stream(fn n -> insert!("initech", "n#{n}") end, max_concurrency: 20)
    |> Stream.run()

    assert Enum.sort(bodies("initech")) == Enum.sort(for n <- 1..20, do: "n#{n}")
    assert [{_pid, _}] = Registry.lookup(MyApp.Tenants.Registry, "initech")
  end

  test "an idle tenant is stopped with its commits uploaded; the next use restores it",
       %{dir: dir} do
    Application.put_env(
      :my_app,
      MyApp.Tenants,
      Keyword.put(Application.fetch_env!(:my_app, MyApp.Tenants), :idle_after, 300)
    )

    insert!("hooli", "async commit")
    [{pid, _}] = Registry.lookup(MyApp.Tenants.Registry, "hooli")
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    # Only S3 has the data now: the local working copy is gone
    for file <- Path.wildcard(Path.join(dir, "hooli.db*")), do: File.rm!(file)

    assert bodies("hooli") == ["async commit"]
  end

  test "MyApp.Tenants.stop/1 stops a tenant; a tenant can be restored from S3 into a file",
       %{dir: dir, repo_config: repo_config} do
    insert!("umbrella", "u1")
    [{pid, _}] = Registry.lookup(MyApp.Tenants.Registry, "umbrella")
    assert :ok = MyApp.Tenants.stop("umbrella")
    refute Process.alive?(pid)
    # used again right away: starts again, even if the Registry hasn't caught up
    assert bodies("umbrella") == ["u1"]
    :ok = MyApp.Tenants.stop("umbrella")

    config = repo_config.("umbrella")
    copy = Path.join(dir, "umbrella-copy.db")

    assert {:ok, _} =
             Ecto.Adapters.Sediment.s3_restore(config[:s3], copy,
               encryption: config[:encryption]
             )

    {:ok, db} = Sediment.Engine.open(copy, encryption: config[:encryption])
    {:ok, stmt} = Sediment.Engine.prepare(db, "SELECT body FROM notes")
    assert {:ok, [["u1"]]} = Sediment.Engine.fetch_all(db, stmt)
    :ok = Sediment.Engine.release(db, stmt)
    :ok = Sediment.Engine.close(db)
  end

  test "a tenant held by another node can't start here; it can once that node lets go",
       %{repo_config: repo_config} do
    # "node-b" holds the tenant's lease
    start_supervised!(
      Supervisor.child_spec(
        {EctoSediment.DynamicRepo,
         repo_config.("wayne")
         |> Keyword.update!(:database, &(&1 <> "-node-b"))
         |> Keyword.update!(:s3, &Keyword.put(&1, :owner, "node-b"))
         |> Keyword.merge(name: nil, log: false)},
        id: :node_b
      )
    )
    |> EctoSediment.DynamicRepo.put_dynamic_repo()

    # connections connect in the background: wait until node-b holds the lease
    EctoSediment.DynamicRepo.query!("SELECT 1")

    ExUnit.CaptureLog.capture_log(fn ->
      assert_raise CaseClauseError, fn -> insert!("wayne", "w1") end
    end)

    assert [] = Registry.lookup(MyApp.Tenants.Registry, "wayne")

    stop_supervised!(:node_b)
    insert!("wayne", "w1")
    assert bodies("wayne") == ["w1"]
  end

  test "a tenant moves to another prefix: restore into a file, import it there",
       %{dir: dir, repo_config: repo_config, prefixes: prefixes, base: base} do
    insert!("stark", "s1")
    :ok = MyApp.Tenants.stop("stark")

    old = repo_config.("stark")
    file = Path.join(dir, "stark-move.db")

    {:ok, _} =
      Ecto.Adapters.Sediment.s3_restore(old[:s3], file, encryption: old[:encryption])

    :ets.insert(prefixes, {"stark", "#{base}/moved/stark/"})
    new = repo_config.("stark")

    {:ok, _} =
      Ecto.Adapters.Sediment.s3_import(new[:s3], file,
        encryption: new[:encryption],
        source_encryption: old[:encryption]
      )

    for file <- Path.wildcard(Path.join(dir, "stark.db*")), do: File.rm!(file)
    insert!("stark", "s2")
    assert bodies("stark") == ["s1", "s2"]
  end

  @tag skip: not can_list?() && "deletes objects with unsigned requests (SeaweedFS)"
  test "deleting a tenant: stop it, delete its files and its prefix; the id starts empty",
       %{dir: dir, repo_config: repo_config} do
    insert!("wonka", "secret")
    :ok = MyApp.Tenants.stop("wonka")

    prefix = repo_config.("wonka")[:s3][:prefix]
    keys = list_objects(prefix)
    assert keys != []
    for key <- keys, do: :ok = delete_object(key)
    for file <- Path.wildcard(Path.join(dir, "wonka.db*")), do: File.rm!(file)

    assert bodies("wonka") == []
  end

  @tag skip: not can_list?() && "copies objects with unsigned requests (SeaweedFS)"
  test "a tenant moves by copying its objects to another prefix, history included",
       %{dir: dir, repo_config: repo_config, prefixes: prefixes, base: base} do
    insert!("tyrell", "t1")
    :ok = MyApp.Tenants.stop("tyrell")

    old = repo_config.("tyrell")[:s3][:prefix]
    new = "#{base}/copied/tyrell/"

    for key <- list_objects(old) do
      :ok = put_object(new <> String.replace_prefix(key, old, ""), get_object(key))
    end

    :ets.insert(prefixes, {"tyrell", new})
    for file <- Path.wildcard(Path.join(dir, "tyrell.db*")), do: File.rm!(file)
    insert!("tyrell", "t2")
    assert bodies("tyrell") == ["t1", "t2"]
  end
end
