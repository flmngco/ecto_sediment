defmodule Ecto.Integration.VectorTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Ecto.Adapters.Sediment.Vector.Query

  alias EctoSediment.DynamicRepo, as: Repo

  defmodule Document do
    use Ecto.Schema

    schema "documents" do
      field(:name, :string)
      field(:embedding, Ecto.Adapters.Sediment.Vector)
      field(:embedding64, Ecto.Adapters.Sediment.Vector64)
    end
  end

  defmodule CreateDocuments do
    use Ecto.Migration

    def change do
      create table(:documents) do
        add(:name, :string)
        add(:embedding, :vector32, size: 3)
        add(:embedding64, :vector64, size: 3)
      end
    end
  end

  setup do
    pid = Repo.start_supervised!(database: Temp.path!())
    Ecto.Migrator.up(Repo, 1, CreateDocuments, log: false, dynamic_repo: pid)

    for {name, v} <- [x: [1, 0, 0], y: [0, 1, 0], xy: [1, 1, 0]] do
      Repo.insert!(%Document{name: to_string(name), embedding: v, embedding64: v})
    end

    :ok
  end

  test "round-trips 32 and 64-bit vectors" do
    assert %Document{embedding: [1.0, 1.0, 0.0], embedding64: [1.0, 1.0, 0.0]} =
             Repo.get_by!(Document, name: "xy")
  end

  test "stores vectors Turso's vector functions understand" do
    assert "[1,1,0]" ==
             Repo.one!(
               from(d in Document,
                 where: d.name == "xy",
                 select: vector_extract(d.embedding)
               )
             )

    %{rows: [[sql]]} =
      Repo.query!("SELECT sql FROM sqlite_schema WHERE name = 'documents'")

    assert sql =~ ~r{"embedding" F32_BLOB ?\(3\)}
    assert sql =~ ~r{"embedding64" F64_BLOB ?\(3\)}
  end

  test "orders by distance to a pinned vector" do
    assert ["x", "xy", "y"] ==
             Repo.all(
               from(d in Document,
                 order_by: vector_distance_cos(d.embedding, ^[1.0, 0.1, 0.0]),
                 select: d.name
               )
             )

    assert ["y", "xy", "x"] ==
             Repo.all(
               from(d in Document,
                 order_by: vector_distance_l2(d.embedding, ^[0, 1, 0]),
                 select: d.name
               )
             )
  end

  test "rows without a vector must be filtered out before computing distances" do
    Repo.insert!(%Document{name: "none"})

    assert_raise Sediment.Error, ~r/Invalid vector type/, fn ->
      Repo.all(
        from(d in Document, order_by: vector_distance_cos(d.embedding, ^[1, 0, 0]))
      )
    end

    assert ["x", "xy", "y"] ==
             Repo.all(
               from(d in Document,
                 where: not is_nil(d.embedding),
                 order_by: vector_distance_cos(d.embedding, ^[1, 0, 0]),
                 select: d.name
               )
             )
  end

  test "distances can be selected" do
    [cos] =
      Repo.all(
        from(d in Document,
          where: d.name == "x",
          select: vector_distance_cos(d.embedding, ^[0, 1, 0])
        )
      )

    assert_in_delta cos, 1.0, 1.0e-6
  end
end
