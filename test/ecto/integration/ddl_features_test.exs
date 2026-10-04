defmodule Ecto.Integration.DdlFeaturesTest do
  # Migration and query features whose SQL is unit tested, run against Turso.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.Sediment.Connection
  alias EctoSediment.DynamicRepo, as: Repo

  defmodule Migration do
    use Ecto.Migration

    def change do
      create table(:parents, primary_key: false) do
        add(:a, :integer, primary_key: true)
        add(:b, :integer, primary_key: true)
      end

      create table(:children) do
        add(
          :pa,
          references(:parents,
            column: :a,
            with: [pb: :b],
            type: :integer,
            on_delete: :delete_all
          )
        )

        add(:pb, :integer)
        add(:name, :string)
      end

      create_if_not_exists(index(:children, [:name]))
      create_if_not_exists(index(:children, [:name]))
      rename(index(:children, [:name]), to: "children_by_name")
      drop_if_exists(index(:children, [:nope]))
      drop_if_exists(table(:nope))
    end
  end

  setup do
    repo = Repo.start_supervised!(database: Temp.path!(), pool_size: 1)
    Ecto.Migrator.up(Repo, 1, Migration, log: false)
    [pool: Ecto.Adapter.lookup_meta(repo).pid]
  end

  test "composite foreign keys, index DDL and rename" do
    Repo.query!("insert into parents values (1, 2)")
    Repo.query!("insert into children (pa, pb, name) values (1, 2, 'x')")

    assert {:error, %Sediment.Error{message: message}} =
             Repo.query("insert into children (pa, pb, name) values (1, 3, 'y')")

    assert message =~ "FOREIGN KEY"

    Repo.query!("delete from parents")
    assert %{rows: [[0]]} = Repo.query!("select count(*) from children")

    assert %{rows: [["children_by_name"]]} =
             Repo.query!(
               "select name from sqlite_master where type = 'index' and tbl_name = 'children'"
             )
  end

  # Repo.explain/3 looks the repo up by name inside ecto_sql, which an
  # unnamed dynamic repo doesn't have; the adapter callback is what we own.
  test "explain", %{pool: pool} do
    sql = ~s(SELECT c0."id" FROM "children" AS c0 WHERE c0."name" = ?)

    assert {:ok, "QUERY PLAN" <> _ = plan} =
             Connection.explain_query(pool, sql, ["x"], [])

    assert plan =~ "children_by_name"

    assert {:ok, instructions} =
             Connection.explain_query(pool, sql, ["x"], type: :instructions)

    assert instructions =~ "opcode"
  end

  test "right and full joins" do
    Repo.query!("insert into parents values (1, 2), (3, 4)")
    Repo.query!("insert into children (pa, pb, name) values (1, 2, 'x')")

    right =
      from(c in "children",
        right_join: p in "parents",
        on: p.a == c.pa,
        select: {c.name, p.a},
        order_by: p.a
      )

    assert Repo.all(right) == [{"x", 1}, {nil, 3}]

    # turso_core 0.8.1 rejects a FULL JOIN whose right-hand join column is
    # indexed (here the primary key); a unary plus avoids the index.
    full =
      from(c in "children", full_join: p in "parents", on: p.a == c.pa, select: count())

    assert_raise Sediment.Error, ~r/FULL OUTER JOIN requires an equality/, fn ->
      Repo.one(full)
    end

    full =
      from(c in "children",
        full_join: p in "parents",
        on: fragment("+?", p.a) == c.pa,
        select: count()
      )

    assert Repo.one(full) == 2
  end
end
