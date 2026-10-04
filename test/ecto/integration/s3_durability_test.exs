defmodule Ecto.Integration.S3DurabilityTest do
  # Async S3 durability (durability: :async) and its sync options, through Ecto:
  # sync: true on repo functions, durability: :sync, s3_flush/2. S3 goes
  # through a proxy that delays every request, so waiting for S3 shows.
  use ExUnit.Case, async: false

  import Ecto.Query
  import EctoSediment.S3Helpers
  import ExUnit.CaptureLog

  alias Ecto.Adapters.Sediment
  alias EctoSediment.DynamicRepo, as: Repo
  alias EctoSediment.LatencyProxy
  alias EctoSediment.S3App
  alias EctoSediment.S3App.Post

  @moduletag :s3
  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()
  @moduletag timeout: 120_000

  # Added to every S3 request
  @delay 300

  defmodule SyncRepo do
    # The S3 guide's recipe: writes default to sync: true, reads don't
    use Ecto.Repo, otp_app: :ecto_sediment, adapter: Ecto.Adapters.Sediment

    @writes [
      :insert,
      :update,
      :delete,
      :insert_or_update,
      :insert_all,
      :update_all,
      :delete_all,
      :transaction
    ]

    @impl true
    def default_options(operation) when operation in @writes, do: [sync: true]
    def default_options(_operation), do: []
  end

  setup_all do
    :ok = ensure_bucket()
  end

  setup %{tmp_dir: dir} do
    %URI{host: host, port: port} = URI.parse(endpoint())

    proxy =
      start_supervised!({LatencyProxy, upstream: {String.to_charlist(host), port}})

    # Explicit, so the tests hold whatever the driver's default is
    s3 =
      s3_opts(unique_prefix("durability"), "ecto-test", durability: :async)
      |> Keyword.put(:endpoint, "http://127.0.0.1:#{LatencyProxy.port(proxy)}")

    config = [
      database: Path.join(dir, "app.db"),
      s3: s3,
      encryption: false,
      pool_size: 2
    ]

    %{config: config, proxy: proxy, dir: dir, s3: s3}
  end

  defp start(config, proxy) do
    pid = Repo.start_supervised!(config)
    S3App.migrate(Repo, pid)
    LatencyProxy.set_delay(proxy, @delay)
    pid
  end

  defp ms(fun) do
    {us, _} = :timer.tc(fun)
    div(us, 1_000)
  end

  defp titles, do: Repo.all(from(p in Post, select: p.title, order_by: p.id))

  defp restored_titles(s3, dir, name) do
    path = Path.join(dir, "#{name}.db")
    {:ok, _} = Sediment.s3_restore(s3, path, encryption: false)
    pid = Repo.start_supervised!(database: path, pool_size: 1, s3: nil)
    titles = titles()
    Supervisor.stop(pid)
    titles
  end

  test "s3_info/1 reports the durability", %{config: config, proxy: proxy} do
    pid = start(config, proxy)
    assert {:ok, %{durability: "async"}} = Sediment.s3_info(pid)
  end

  test "S3 repos default to async durability", %{config: config, proxy: proxy} do
    pid = config |> update_in([:s3], &Keyword.delete(&1, :durability)) |> start(proxy)
    assert {:ok, %{durability: "async"}} = Sediment.s3_info(pid)
  end

  test "commits don't wait for S3; sync: true on any repo function does",
       %{config: config, proxy: proxy} do
    start(config, proxy)

    assert ms(fn -> Repo.insert!(%Post{title: "async"}) end) < @delay

    waits = [
      insert: fn -> Repo.insert!(%Post{title: "insert"}, sync: true) end,
      update: fn ->
        Post
        |> Repo.get_by!(title: "insert")
        |> Ecto.Changeset.change(views: 1)
        |> Repo.update!(sync: true)
      end,
      delete: fn ->
        Post |> Repo.get_by!(title: "insert") |> Repo.delete!(sync: true)
      end,
      insert_all: fn ->
        now = NaiveDateTime.utc_now(:second)
        row = %{title: "all", views: 0, inserted_at: now, updated_at: now}
        Repo.insert_all(Post, [row], sync: true)
      end,
      update_all: fn -> Repo.update_all(Post, [inc: [views: 1]], sync: true) end,
      query: fn -> Repo.query!("UPDATE posts SET views = views + 1", [], sync: true) end,
      transaction: fn ->
        Repo.transaction(fn -> Repo.insert!(%Post{title: "tx"}) end, sync: true)
      end
    ]

    for {name, fun} <- waits do
      assert ms(fun) >= @delay, "#{name} with sync: true didn't wait for S3"
    end

    # Inside a transaction a statement's sync: true doesn't wait: the
    # transaction's own option applies at COMMIT
    {:ok, took} =
      Repo.transaction(fn ->
        ms(fn -> Repo.insert!(%Post{title: "in-tx"}, sync: true) end)
      end)

    assert took < @delay
  end

  test "durability: :sync makes every commit wait for S3", %{
    config: config,
    proxy: proxy
  } do
    config
    |> put_in([:s3, :durability], :sync)
    |> start(proxy)

    assert ms(fn -> Repo.insert!(%Post{title: "sync"}) end) >= @delay
  end

  test "a repo can default writes to sync: true with default_options/1; reads don't wait",
       ctx do
    config = [
      database: Path.join(ctx.dir, "sync_repo.db"),
      s3: ctx.s3,
      encryption: false,
      pool_size: 1
    ]

    start_supervised!({SyncRepo, config})
    S3App.migrate(SyncRepo, SyncRepo)
    LatencyProxy.set_delay(ctx.proxy, @delay)

    assert ms(fn -> SyncRepo.insert!(%Post{title: "synced by default"}) end) >= @delay

    assert ms(fn -> SyncRepo.insert!(%Post{title: "opted out"}, sync: false) end) <
             @delay

    # with that upload still in flight, and with S3 down, reads return at once
    assert ms(fn -> SyncRepo.all(Post) end) < @delay
    LatencyProxy.set_down(ctx.proxy, true)
    assert ms(fn -> assert [_, _] = SyncRepo.all(Post) end) < @delay
    assert ms(fn -> SyncRepo.get_by!(Post, title: "opted out") end) < @delay
    LatencyProxy.set_down(ctx.proxy, false)
  end

  # sync: true makes a statement wait for its own commit: a read commits
  # nothing, so it neither waits for other connections' uploads nor fails
  # when S3 is down
  test "a read with sync: true doesn't wait for S3 or fail without it",
       %{config: config, proxy: proxy} do
    start(config, proxy)
    Repo.insert!(%Post{title: "p"})
    LatencyProxy.set_delay(proxy, 2_000)
    # an upload that takes seconds is in flight
    Repo.insert!(%Post{title: "q"})

    assert ms(fn -> assert [_, _] = Repo.all(Post, sync: true) end) < @delay

    assert ms(fn -> Repo.query!("SELECT count(*) FROM posts", [], sync: true) end) <
             @delay

    LatencyProxy.set_down(proxy, true)

    assert ms(fn -> assert %Post{} = Repo.get_by!(Post, [title: "q"], sync: true) end) <
             @delay

    assert ms(fn ->
             assert {:ok, _} = Repo.transaction(fn -> Repo.all(Post) end, sync: true)
           end) < @delay

    LatencyProxy.set_down(proxy, false)
  end

  test "a commit is visible before it is durable; s3_flush/2 waits until it is",
       %{config: config, proxy: proxy, s3: s3, dir: dir} do
    pid = start(config, proxy)
    started = System.monotonic_time(:millisecond)

    for i <- 1..5, do: Repo.insert!(%Post{title: "p#{i}"})

    # Another pooled connection sees the commits at once: sooner than a
    # single upload to S3 can take
    parent = self()

    Task.start(fn ->
      Repo.put_dynamic_repo(pid)
      send(parent, {:seen, Repo.aggregate(Post, :count)})
    end)

    assert_receive {:seen, 5}, 1_000
    assert System.monotonic_time(:millisecond) - started < @delay

    assert Sediment.s3_flush(pid, 10_000) == :ok
    assert {:ok, %{pending_bytes: 0} = info} = Sediment.s3_info(Repo)
    assert info.durable_offset == info.committed_offset

    # So a restore elsewhere, while this writer keeps running, has them all
    assert restored_titles(s3, dir, "after-flush") == for(i <- 1..5, do: "p#{i}")
  end

  test "a checkpoint and a clean stop make every commit durable",
       %{config: config, proxy: proxy, s3: s3, dir: dir} do
    pid = start(config, proxy)

    for i <- 1..5, do: Repo.insert!(%Post{title: "before-checkpoint-#{i}"})
    assert Sediment.checkpoint(pid) == :ok
    before_checkpoint = for i <- 1..5, do: "before-checkpoint-#{i}"
    assert restored_titles(s3, dir, "after-checkpoint") == before_checkpoint

    Repo.put_dynamic_repo(pid)
    for i <- 1..5, do: Repo.insert!(%Post{title: "before-stop-#{i}"})
    Supervisor.stop(pid)

    assert restored_titles(s3, dir, "after-stop") ==
             before_checkpoint ++ for(i <- 1..5, do: "before-stop-#{i}")
  end

  # The pool waits for the close, which uploads what is pending, instead of
  # killing it after the default 5 s shutdown timeout
  test "stopping the repo uploads pending commits and closes the database before it returns",
       %{config: config, proxy: proxy, s3: s3, dir: dir} do
    pid = start(config, proxy)
    LatencyProxy.set_delay(proxy, 2_000)
    for i <- 1..20, do: Repo.insert!(%Post{title: "p#{i}"})

    Supervisor.stop(pid)
    assert open_files(dir) == []

    LatencyProxy.set_delay(proxy, 0)
    assert restored_titles(s3, dir, "after-stop") == for(i <- 1..20, do: "p#{i}")
  end

  # Node A's queued commits are lost when node B takes over the prefix;
  # A reconnects and restores B's state, and its flushes fail until the
  # application acknowledges the loss
  test "a loss is reported until s3_acknowledge_loss/1",
       %{config: config, proxy: proxy, s3: s3, dir: dir} do
    a = start(Keyword.merge(config, backoff_min: 100, backoff_max: 500), proxy)
    LatencyProxy.set_delay(proxy, 0)
    Repo.insert!(%Post{title: "durable"}, sync: true)

    LatencyProxy.set_down(proxy, true)
    Repo.insert!(%Post{title: "lost"})

    # B: the same owner (takes the lease at once), straight to S3
    direct = Keyword.put(s3, :endpoint, endpoint())

    b =
      Repo.start_supervised!(
        database: Path.join(dir, "b.db"),
        s3: direct,
        encryption: false,
        pool_size: 1
      )

    assert titles() == ["durable"]

    capture_log(fn ->
      LatencyProxy.set_down(proxy, false)
      Supervisor.stop(b)

      # A finds it was fenced, reconnects and restores what is durable
      Repo.put_dynamic_repo(a)
      # (a statement, as any request would run, makes it notice the fence)
      assert wait_until(fn ->
               _ = Repo.query("SELECT 1")
               match?({:ok, %{lost: %{}}}, Sediment.s3_info(a))
             end)
    end)

    assert titles() == ["durable"]
    assert {:error, reason} = Sediment.s3_flush(a, 5_000)
    assert to_string(reason) =~ "lost"

    assert_raise Elixir.Sediment.Error, ~r/lost/, fn ->
      Repo.insert!(%Post{title: "synced"}, sync: true)
    end

    assert {:ok, %{} = lost} = Sediment.s3_acknowledge_loss(Repo)
    assert {:ok, %{lost: nil}} = Sediment.s3_info(a)
    assert Sediment.s3_flush(a, 5_000) == :ok
    Repo.insert!(%Post{title: "synced again"}, sync: true)
    assert is_map(lost)
  end

  defp wait_until(fun, attempts \\ 300) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && wait_until(fun, attempts - 1)
    end
  end

  # Scripts and Mix tasks (seeds!) end with System.halt/1, which doesn't stop
  # the repo; the adapter's at_exit hook uploads what is still queued
  test "a script's commits are durable when it exits", %{config: config, proxy: proxy} do
    pid = start(config, proxy)
    Supervisor.stop(pid)
    LatencyProxy.set_delay(proxy, 100)

    config_path = Path.join(Path.dirname(config[:database]), "exit_config.term")
    File.write!(config_path, :erlang.term_to_binary(config))
    script = Path.expand("../../support/scripts/s3_exit_writer.exs", __DIR__)

    {output, 0} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-compile",
          "--no-deps-check",
          "--no-start",
          script,
          config_path,
          "30"
        ],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output =~ "acked 30"
    LatencyProxy.set_delay(proxy, 0)

    fresh = Path.join(Path.dirname(config[:database]), "fresh.db")
    Repo.start_supervised!(Keyword.put(config, :database, fresh))
    assert titles() == for(i <- 1..30, do: "exit-#{i}")
  end

  defp open_files(dir) do
    for fd <- File.ls!("/proc/self/fd"),
        {:ok, target} <- [File.read_link("/proc/self/fd/" <> fd)],
        String.starts_with?(target, dir),
        do: target
  end

  test "sync: true reports a commit it can't make durable yet; it becomes durable later",
       %{config: config, proxy: proxy, s3: s3, dir: dir} do
    start(config, proxy)
    LatencyProxy.set_down(proxy, true)

    capture_log(fn ->
      error =
        assert_raise Elixir.Sediment.Error, fn ->
          Repo.insert!(%Post{title: "not-yet-durable"}, sync: true, sync_timeout: 1_000)
        end

      assert error.message =~ "committed locally, but not known to be durable in S3"
    end)

    # The commit wasn't rolled back: it is visible, and becomes durable once
    # S3 is back
    assert titles() == ["not-yet-durable"]
    LatencyProxy.set_down(proxy, false)
    assert Sediment.s3_flush(Repo, 30_000) == :ok
    assert restored_titles(s3, dir, "after-outage") == ["not-yet-durable"]
  end
end
