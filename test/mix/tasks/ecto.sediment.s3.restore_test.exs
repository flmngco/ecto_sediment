defmodule Mix.Tasks.Ecto.Sediment.S3.RestoreTest do
  use ExUnit.Case, async: false

  alias EctoSediment.DynamicRepo
  alias Mix.Tasks.Ecto.Sediment.S3.Restore

  setup do
    Application.put_env(:ecto_sediment, DynamicRepo, database: Temp.path!(), log: false)
    on_exit(fn -> Application.delete_env(:ecto_sediment, DynamicRepo) end)
  end

  defp run(args), do: Restore.run(["-r", inspect(DynamicRepo), "--no-compile" | args])

  test "needs --output" do
    assert_raise Mix.Error, ~r/needs --output/, fn -> run([]) end
  end

  test "rejects a malformed --at" do
    assert_raise Mix.Error,
                 ~r/--at must be an ISO 8601 timestamp, got: yesterday/,
                 fn ->
                   run(["-o", Temp.path!(), "--at", "yesterday"])
                 end
  end

  test "needs exactly one repo" do
    assert_raise Mix.Error, ~r/exactly one repo/, fn ->
      Restore.run(["-r", inspect(DynamicRepo), "-r", "Other.Repo", "-o", Temp.path!()])
    end
  end

  test "fails clearly for a repo without :s3" do
    assert_raise Mix.Error, ~r/is not configured with :s3/, fn ->
      run(["-o", Temp.path!()])
    end

    assert {:error, "EctoSediment.DynamicRepo is not configured with :s3"} =
             Ecto.Adapters.Sediment.s3_restore(DynamicRepo, Temp.path!())
  end

  # Every target flag reaches the restore, which refuses more than one: none
  # is picked and the others dropped. A repeated flag fails the task.
  test "refuses more than one target flag, and a repeated one" do
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
      encryption: false,
      log: false
    )

    output = Temp.path!()

    for flags <- [
          ["--epoch", "7", "--epoch-start", "9"],
          ["--at", "2026-10-20T12:00:00Z", "--epoch-start", "7"],
          ["--at", "2026-10-20T12:00:00Z", "--epoch", "00000000000000000003-0000000002"]
        ] do
      assert_raise Mix.Error, ~r/give one of :at, :epoch and :epoch_start/, fn ->
        run(["-o", output | flags])
      end

      refute File.exists?(output)
    end

    for {flags, name} <- [
          {["--epoch", "1", "--epoch", "2"], "--epoch"},
          {["--epoch-start", "1", "--epoch-start", "2"], "--epoch-start"},
          {["--at", "2026-10-20T12:00:00Z", "--at", "2026-10-21T12:00:00Z"], "--at"}
        ] do
      assert_raise Mix.Error, ~r/#{name} given more than once/, fn ->
        run(["-o", output | flags])
      end
    end
  end
end
