defmodule Ecto.Adapters.Sediment.Connection.CoalesceTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import Ecto.Adapters.Sediment.TestHelpers

  alias EctoSediment.Schemas.Schema

  test "coalesce" do
    query =
      Schema
      |> select([s], coalesce(s.x, 5))
      |> plan()

    assert ~s{SELECT coalesce(s0."x", 5) FROM "schema" AS s0} == all(query)
  end
end
