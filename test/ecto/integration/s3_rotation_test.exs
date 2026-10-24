defmodule Ecto.Integration.S3RotationTest do
  # Key rotation through the adapter: per repo (a named repo, a dynamic
  # repo's configuration) and over many dynamic tenant repos, each paused
  # only for its own rekey. mix test --only s3
  use ExUnit.Case, async: false

  import EctoSediment.S3Helpers

  alias Ecto.Adapters.Sediment, as: Adapter
  alias EctoSediment.DynamicRepo, as: Repo

  @moduletag :s3
  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()

  @k1 String.duplicate("a1", 32)
  @k2 String.duplicate("b2", 32)

  setup_all do
    :ok = ensure_bucket()
  end

  setup do
    on_exit(fn -> Application.delete_env(:ecto_sediment, Repo) end)
  end

  defp ring(ids), do: [keys: Enum.map(ids, &{&1, key(&1)}), cipher: "aegis256"]

  defp key("r1"), do: @k1
  defp key("r2"), do: @k2

  defp config(dir, name, ids) do
    [
      database: Path.join(dir, "#{name}.db"),
      s3: s3_opts(unique_prefix("rotation-#{name}")),
      encryption: ring(ids),
      pool_size: 1,
      log: false
    ]
  end

  # Starts a dynamic repo (name: nil) with `config`, runs `fun` in it, stops it.
  defp with_repo(config, fun) do
    {:ok, pid} = Repo.start_link([name: nil] ++ config)
    Repo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      Supervisor.stop(pid)
    end
  end

  defp write!(config, values) do
    with_repo(config, fn ->
      Repo.query!("CREATE TABLE IF NOT EXISTS t (v TEXT)")
      Enum.each(values, &Repo.query!("INSERT INTO t VALUES (?)", [&1]))
    end)
  end

  defp rows(config),
    do: with_repo(config, fn -> Repo.query!("SELECT v FROM t").rows end)

  test "s3_rekey, s3_key_census and s3_release_key on a dynamic repo's configuration",
       %{
         tmp_dir: dir
       } do
    config = config(dir, "dynamic", ["r1"])
    write!(config, ["a"])
    both = Keyword.put(config, :encryption, ring(["r2", "r1"]))

    assert {:ok, %{current: "r1", retained: %{}}} = Adapter.s3_key_census(config)
    assert {:ok, %{from: "r1", to: "r2"}} = Adapter.s3_rekey(both)
    assert {:ok, :current} = Adapter.s3_rekey(both)

    assert {:ok, %{current: "r2", retained: %{"r1" => [_ | _]}}} =
             Adapter.s3_key_census(config)

    assert rows(Keyword.put(config, :encryption, ring(["r2"]))) == [["a"]]

    assert {:ok, %{key: "r1", epochs: [_ | _]}} = Adapter.s3_release_key(both, "r1")
    assert {:ok, %{current: "r2", retained: %{}}} = Adapter.s3_key_census(config)
  end

  test "s3_rekey and s3_release_key on a named repo, with options", %{tmp_dir: dir} do
    config = config(dir, "named", ["r1"])
    write!(config, ["a"])

    Application.put_env(
      :ecto_sediment,
      Repo,
      Keyword.put(config, :encryption, ring(["r1", "r2"]))
    )

    # The ring's active key is r1, its current one: :to moves it.
    assert {:ok, :current} = Adapter.s3_rekey(Repo)
    assert {:ok, %{to: "r2"}} = Adapter.s3_rekey(Repo, to: "r2")
    assert {:ok, %{key: "r1"}} = Adapter.s3_release_key(Repo, "r1")
    assert {:ok, %{current: "r2", retained: %{}}} = Adapter.s3_key_census(Repo)
  end

  test "a running repo is refused, by name; it is never stopped", %{tmp_dir: dir} do
    config = config(dir, "running", ["r1"])
    write!(config, ["a"])
    both = Keyword.put(config, :encryption, ring(["r2", "r1"]))

    {:ok, pid} = Repo.start_link([name: nil] ++ config)
    assert {:error, message} = Adapter.s3_rekey(both)
    assert message =~ "the dynamic repo #{inspect(pid)} is running in this VM"
    assert message =~ "stop it first"
    assert {:error, _} = Adapter.s3_release_key(both, "r1")
    assert %{failed: [{"t", ^message}]} = Adapter.s3_rekey_many([{"t", both}])
    assert Process.alive?(pid)
    Supervisor.stop(pid)

    Application.put_env(:ecto_sediment, Repo, both)
    start_supervised!(Repo)
    assert {:error, message} = Adapter.s3_rekey(Repo)
    assert message =~ "the repo EctoSediment.DynamicRepo is running in this VM"
    stop_supervised!(Repo)

    assert {:ok, %{to: "r2"}} = Adapter.s3_rekey(Repo)
  end

  test "a reopen failing after the rekey fails the tenant, the rekey's result kept",
       %{tmp_dir: dir} do
    config = config(dir, "reopen", ["r1"])
    write!(config, ["a"])
    both = Keyword.put(config, :encryption, ring(["r2", "r1"]))

    assert %{
             rekeyed: [],
             failed: [{"t", {:around_failed, :reopen_failed, {:ok, %{to: "r2"}}}}]
           } =
             Adapter.s3_rekey_many([{"t", both}],
               around: fn {"t", _config}, rekey ->
                 rekey.()
                 {:error, :reopen_failed}
               end
             )

    assert %{current: ["t"], failed: []} = Adapter.s3_rekey_many([{"t", both}])
  end

  test "rekey_many over dynamic tenant repos, each closed and reopened around its rekey",
       %{
         tmp_dir: dir
       } do
    tenants = for id <- ["acme", "globex"], into: %{}, do: {id, config(dir, id, ["r1"])}
    Enum.each(tenants, fn {id, config} -> write!(config, [id]) end)

    # The application's tenants: a repo per tenant under a supervisor (not
    # linked to whoever opens it: around: runs in a task of its own).
    running = :ets.new(:running, [:public])
    sup = start_supervised!(DynamicSupervisor)

    open = fn id, config ->
      {:ok, pid} = DynamicSupervisor.start_child(sup, {Repo, [name: nil] ++ config})
      :ets.insert(running, {id, pid})
    end

    close = fn id ->
      [{^id, pid}] = :ets.lookup(running, id)
      :ok = DynamicSupervisor.terminate_child(sup, pid)
      :ets.delete(running, id)
    end

    Enum.each(tenants, fn {id, config} -> open.(id, config) end)
    test = self()

    # After the rekey each tenant reopens with both keys, as the rings
    # hold both until the old key is released.
    result =
      Adapter.s3_rekey_many(
        for(
          {id, config} <- tenants,
          do: {id, Keyword.put(config, :encryption, ring(["r2", "r1"]))}
        ),
        around: fn {id, config}, rekey ->
          # The ring hidden, still the one the repo reopens with.
          assert %Sediment.S3.Keys.Hidden{} = config[:encryption]
          refute inspect(config, limit: :infinity) =~ @k1
          close.(id)
          [other] = Map.keys(tenants) -- [id]
          send(test, {:paused, id, other_running: :ets.member(running, other)})

          try do
            rekey.()
          after
            open.(id, config)
          end
        end
      )

    assert %{rekeyed: rekeyed, failed: []} = result
    assert Enum.sort(rekeyed) == ["acme", "globex"]

    # One tenant at a time paused: the other was up meanwhile.
    assert_received {:paused, "acme", other_running: true}
    assert_received {:paused, "globex", other_running: true}

    for {id, _config} <- tenants do
      [{^id, pid}] = :ets.lookup(running, id)
      Repo.put_dynamic_repo(pid)
      assert Repo.query!("SELECT v FROM t").rows == [[id]]
      close.(id)
    end

    census = Adapter.s3_key_census_many(Map.to_list(tenants))
    assert %{"r2" => %{current: current}} = census.keys
    assert Enum.sort(current) == ["acme", "globex"]
    refute Sediment.S3.removable?(census, "r1")

    for {id, config} <- tenants,
        do: assert(rows(Keyword.put(config, :encryption, ring(["r2"]))) == [[id]])

    both =
      for {id, config} <- tenants,
          do: {id, Keyword.put(config, :encryption, ring(["r2", "r1"]))}

    assert %{released: released, failed: []} = Adapter.s3_release_key_many(both, "r1")
    assert Enum.sort(released) == ["acme", "globex"]
    assert Sediment.S3.removable?(Adapter.s3_key_census_many(both), "r1")
  end
end
