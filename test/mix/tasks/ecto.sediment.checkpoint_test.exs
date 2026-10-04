defmodule Mix.Tasks.Ecto.Sediment.CheckpointTest do
  use ExUnit.Case, async: false

  alias EctoSediment.DynamicRepo
  alias Mix.Tasks.Ecto.Sediment.Checkpoint

  setup do
    Application.put_env(:ecto_sediment, DynamicRepo, database: Temp.path!(), log: false)
    on_exit(fn -> Application.delete_env(:ecto_sediment, DynamicRepo) end)
  end

  test "checkpoints the repo" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Checkpoint.run(["-r", inspect(DynamicRepo), "--no-compile", "--no-deps-check"])
    assert_received {:mix_shell, :info, ["Checkpointed EctoSediment.DynamicRepo"]}
  end
end
