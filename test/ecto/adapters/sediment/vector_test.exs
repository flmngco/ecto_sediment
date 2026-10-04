defmodule Ecto.Adapters.Sediment.VectorTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import Ecto.Adapters.Sediment.TestHelpers
  import Ecto.Adapters.Sediment.Vector.Query

  alias Ecto.Adapters.Sediment.DataType
  alias Ecto.Adapters.Sediment.Vector
  alias Ecto.Adapters.Sediment.Vector64

  describe "Vector" do
    test "casts lists of numbers to floats" do
      assert Vector.cast([1, 2.5]) == {:ok, [1.0, 2.5]}
      assert Vector.cast(["a"]) == :error
      assert Vector.cast("[1]") == :error
    end

    test "dumps to vector32 blobs and loads them back" do
      assert {:ok, blob} = Vector.dump([1.0, 0.0, 2.0])

      assert blob ==
               <<1.0::float-32-little, 0.0::float-32-little, 2.0::float-32-little>>

      assert Vector.load(blob) == {:ok, [1.0, 0.0, 2.0]}
      assert Vector.load(<<1, 2, 3>>) == :error
    end
  end

  describe "Vector64" do
    test "dumps to vector64 blobs with the float64 type byte" do
      assert {:ok, blob} = Vector64.dump([1.0, 2.0])
      assert blob == <<1.0::float-64-little, 2.0::float-64-little, 2>>
      assert Vector64.load(blob) == {:ok, [1.0, 2.0]}
      assert Vector64.load(<<1.0::float-64-little>>) == :error
    end
  end

  describe "invalid values" do
    test "are rejected by cast, dump and load" do
      assert Vector.dump("[1, 2]") == :error
      assert Vector64.cast([1, 2]) == {:ok, [1.0, 2.0]}
      assert Vector64.cast([:a]) == :error
      assert Vector64.dump(%{}) == :error
      assert Vector64.load(nil) == :error
      assert Vector.load(nil) == :error
    end
  end

  describe "column types" do
    test "vector columns" do
      assert DataType.column_type(:vector, nil) == "F32_BLOB"
      assert DataType.column_type(:vector32, size: 3) == "F32_BLOB(3)"
      assert DataType.column_type(:vector64, size: 8) == "F64_BLOB(8)"
    end
  end

  describe "query macros" do
    test "distance functions" do
      query =
        "docs"
        |> select([d], vector_distance_l2(d.embedding, d.other))
        |> order_by([d], vector_distance_cos(d.embedding, d.other))
        |> plan()

      assert all(query) ==
               ~s{SELECT vector_distance_l2(d0."embedding", d0."other") FROM "docs" AS d0 } <>
                 ~s{ORDER BY vector_distance_cos(d0."embedding", d0."other")}
    end

    test "pinned lists are dumped as vector32 blobs" do
      {query, _cast, dump} =
        from(d in "docs", select: vector_distance_dot(d.embedding, ^[1, 2]))
        |> then(&Ecto.Adapter.Queryable.plan_query(:all, Ecto.Adapters.Sediment, &1))

      assert IO.iodata_to_binary(Ecto.Adapters.Sediment.Connection.all(query)) =~
               ~s{vector_distance_dot(d0."embedding", CAST(? AS BLOB))}

      assert [{:blob, <<1.0::float-32-little, 2.0::float-32-little>>}] = dump
    end

    test "jaccard and extract" do
      query =
        "docs"
        |> select([d], {vector_distance_jaccard(d.a, d.b), vector_extract(d.a)})
        |> plan()

      assert all(query) ==
               ~s{SELECT vector_distance_jaccard(d0."a", d0."b"), vector_extract(d0."a") } <>
                 ~s{FROM "docs" AS d0}
    end
  end
end
