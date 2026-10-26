defmodule Mix.Tasks.Ecto.Sediment.S3.RotationTest do
  # mix ecto.sediment.s3.rekey, .release_key and .key_census: one line per
  # repo, a non-zero exit (Mix.Error) on any result but {:ok, _}.
  use ExUnit.Case, async: false

  import EctoSediment.S3Helpers

  alias EctoSediment.DynamicRepo
  alias Mix.Tasks.Ecto.Sediment.S3.KeyCensus
  alias Mix.Tasks.Ecto.Sediment.S3.Rekey
  alias Mix.Tasks.Ecto.Sediment.S3.ReleaseKey

  @k1 String.duplicate("c1", 32)
  @k2 String.duplicate("d2", 32)

  defp ring(ids),
    do: [
      keys: Enum.map(ids, &{&1, %{"r1" => @k1, "r2" => @k2}[&1]}),
      cipher: "aegis256"
    ]

  setup do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Application.delete_env(:ecto_sediment, DynamicRepo)
    end)
  end

  defp repo, do: ["-r", inspect(DynamicRepo), "--no-compile"]

  defp output do
    receive do
      {:mix_shell, kind, [line]} when kind in [:info, :error] -> [line | output()]
    after
      0 -> []
    end
  end

  test "need a repo, and the release a key id" do
    assert_raise Mix.Error, ~r/needs a repo/, fn -> Rekey.run(["--no-compile"]) end
    Application.put_env(:ecto_sediment, DynamicRepo, database: Temp.path!(), log: false)
    assert_raise Mix.Error, ~r/needs one KEY_ID/, fn -> ReleaseKey.run(repo()) end
  end

  @tag :s3
  test "rekey, census and release of a named repo; a running repo fails the task" do
    :ok = ensure_bucket()
    database = Temp.path!()

    config = [
      database: database,
      s3: s3_opts(unique_prefix("tasks")),
      pool_size: 1,
      log: false
    ]

    Application.put_env(
      :ecto_sediment,
      DynamicRepo,
      config ++ [encryption: ring(["r1"])]
    )

    start_supervised!(DynamicRepo)
    DynamicRepo.query!("CREATE TABLE t (v TEXT)")
    DynamicRepo.query!("INSERT INTO t VALUES ('a')")

    Application.put_env(
      :ecto_sediment,
      DynamicRepo,
      config ++ [encryption: ring(["r2", "r1"])]
    )

    # Running: refused, a non-zero exit, the repo untouched.
    assert_raise Mix.Error, ~r/1 of 1 repos failed/, fn -> Rekey.run(repo()) end
    assert [line] = output()

    assert line =~
             "rekey failed: the repo EctoSediment.DynamicRepo is running in this VM"

    assert line =~ "stop it first"
    assert %{rows: [["a"]]} = DynamicRepo.query!("SELECT v FROM t")
    stop_supervised!(DynamicRepo)

    KeyCensus.run(repo())
    assert output() == ["EctoSediment.DynamicRepo: current r1; retained: none"]

    Rekey.run(repo())
    assert [line] = output()
    assert line =~ ~r/EctoSediment.DynamicRepo: rekeyed from r1 to r2 \(epoch .+\)/

    Rekey.run(repo())
    assert output() == ["EctoSediment.DynamicRepo: under the key already"]

    KeyCensus.run(repo())
    assert [line] = output()
    assert line =~ ~r/current r2; retained: r1 \(\d+ epochs\)/

    # The current key can't be released: a non-zero exit.
    assert_raise Mix.Error, ~r/1 of 1 repos failed/, fn ->
      ReleaseKey.run(["r2" | repo()])
    end

    assert [line] = output()
    assert line =~ "release failed"

    ReleaseKey.run(["r1" | repo()])
    assert [line] = output()
    assert line =~ ~r/released key r1 \(\d+ epochs dropped\)/

    KeyCensus.run(repo())
    assert output() == ["EctoSediment.DynamicRepo: current r2; retained: none"]
  end

  @tag :s3
  test "the census fails the task for a location it can't read" do
    s3 = [
      bucket: "b",
      prefix: "p",
      endpoint: "http://127.0.0.1:1",
      access_key_id: "a",
      secret_access_key: "s"
    ]

    Application.put_env(:ecto_sediment, DynamicRepo,
      database: Temp.path!(),
      s3: s3,
      log: false
    )

    assert_raise Mix.Error, ~r/1 of 1 repos failed/, fn -> KeyCensus.run(repo()) end
    assert [line] = output()
    assert line =~ "census failed"
  end

  # A misaddressed repo reads "no database": never an outcome, and never a
  # sign that a key can go.
  @tag :s3
  test "the census, rekey and release fail the task where no database is" do
    :ok = ensure_bucket()

    for {case, s3} <- [
          {"an empty prefix", s3_opts(unique_prefix("absent"))},
          {"a bucket that doesn't exist",
           Keyword.put(
             s3_opts("p"),
             :bucket,
             "rotation-none-#{System.unique_integer([:positive])}"
           )}
        ] do
      Application.put_env(:ecto_sediment, DynamicRepo,
        database: Temp.path!(),
        s3: s3,
        encryption: ring(["r2", "r1"]),
        log: false
      )

      for run <- [
            fn -> KeyCensus.run(repo()) end,
            fn -> Rekey.run(repo()) end,
            fn -> ReleaseKey.run(["r1" | repo()]) end
          ] do
        assert_raise Mix.Error, ~r/1 of 1 repos failed/, run
        assert [line] = output()

        assert line =~
                 "no database at #{s3[:bucket]}/#{s3[:prefix]}: wrong bucket or prefix?",
               case
      end
    end
  end

  # The tasks and s3_rekey/2 in a VM of their own, without :ecto started (as
  # in a project's `mix`, or a release's eval): the running-repo check needs
  # no registry.
  @tag :s3
  test "the tasks and s3_rekey/2 run in a fresh VM without :ecto" do
    :ok = ensure_bucket()
    s3 = s3_opts(unique_prefix("fresh-vm"))

    config =
      inspect(
        [database: Temp.path!(), s3: s3, encryption: ring(["r2", "r1"]), log: false],
        limit: :infinity
      )

    put = "Application.put_env(:ecto_sediment, EctoSediment.DynamicRepo, #{config});"

    {output, 0} =
      fresh_vm(
        "Application.ensure_all_started(:sediment); false = :ecto in Enum.map(Application.started_applications(), &elem(&1, 0)); " <>
          "IO.inspect(Ecto.Adapters.Sediment.s3_rekey(#{config}))"
      )

    assert output =~ ~s("s3 config: no database at)
    refute output =~ "details withheld"

    for task <- [
          ~s("ecto.sediment.s3.key_census", ["-r", "EctoSediment.DynamicRepo"]),
          ~s("ecto.sediment.s3.rekey", ["-r", "EctoSediment.DynamicRepo"]),
          ~s("ecto.sediment.s3.release_key", ["r1", "-r", "EctoSediment.DynamicRepo"])
        ] do
      {output, status} = fresh_vm(put <> "Mix.Task.run(#{task})")
      assert status != 0, output

      assert output =~
               "no database at #{s3[:bucket]}/#{s3[:prefix]}: wrong bucket or prefix?",
             output

      refute output =~ "details withheld"
    end
  end

  defp fresh_vm(code) do
    System.cmd(
      "mix",
      ["run", "--no-start", "--no-compile", "--no-deps-check", "-e", code],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
