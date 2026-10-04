defmodule Ecto.Adapters.Sediment.UpdateTest do
  use ExUnit.Case, async: true

  import Ecto.Adapters.Sediment.TestHelpers

  test "update" do
    query = update(nil, "schema", [:x, :y], [id: 1], [])

    assert ~s{UPDATE "schema" SET } <>
             ~s{"x" = ?, "y" = ? } <>
             ~s{WHERE "id" = ?} == query

    query = update(nil, "schema", [:x, :y], [id: 1], [:z])

    assert ~s{UPDATE "schema" SET } <>
             ~s{"x" = ?, "y" = ? } <>
             ~s{WHERE "id" = ? } <>
             ~s{RETURNING "z"} == query
  end
end
