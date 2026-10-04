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
end
