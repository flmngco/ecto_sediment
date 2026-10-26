defmodule Ecto.Adapters.Sediment.ExportOptionsTest do
  # export_sqlite/3 refuses an option it doesn't read (a point in time is
  # never exported as the latest state), writing nothing.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Sediment, as: Adapter
  alias EctoSediment.DynamicRepo

  setup do
    Application.put_env(:ecto_sediment, DynamicRepo, database: Temp.path!(), log: false)
    on_exit(fn -> Application.delete_env(:ecto_sediment, DynamicRepo) end)
    %{dest: Temp.path!()}
  end

  test "an option it doesn't read is refused, writing nothing", %{dest: dest} do
    s3 = [bucket: "b", prefix: "p"]

    for {repo_or_s3, opts} <- [
          {DynamicRepo, [at: DateTime.utc_now()]},
          {DynamicRepo, [epoch: 3]},
          {DynamicRepo, [from_s3: s3]},
          {s3, [source: Temp.path!()]},
          {s3, [epoch_start: 1]}
        ] do
      [{name, _}] = opts

      assert {:error,
              "Ecto.Adapters.Sediment.export_sqlite/3: unknown option " <> shown} =
               Adapter.export_sqlite(repo_or_s3, dest, opts)

      assert shown == inspect(name)
      refute File.exists?(dest)
    end
  end
end
