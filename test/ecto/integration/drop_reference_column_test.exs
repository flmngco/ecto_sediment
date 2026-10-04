defmodule Ecto.Integration.DropReferenceColumnTest do
  # turso_core 0.8.1 can't drop a column that has its own REFERENCES, so the
  # down of `add :x, references(...)` fails; a table rebuild works (see the
  # migrating guide).
  use ExUnit.Case, async: false

  alias EctoSediment.DynamicRepo, as: Repo

  defmodule CreateBooks do
    use Ecto.Migration

    def change do
      create(table(:authors))

      create table(:books) do
        add(:title, :string)
      end
    end
  end

  defmodule AddAuthor do
    use Ecto.Migration

    def change do
      alter table(:books) do
        add(:author_id, references(:authors, on_delete: :nilify_all))
      end
    end
  end

  defmodule AddAuthorRebuildDown do
    use Ecto.Migration

    def up, do: AddAuthor.change()

    def down do
      create table(:books_new) do
        add(:title, :string)
      end

      execute("INSERT INTO books_new (id, title) SELECT id, title FROM books")
      drop(table(:books))
      rename(table(:books_new), to: table(:books))
    end
  end

  setup do
    Repo.start_supervised!(database: Temp.path!(), pool_size: 1)
    :ok = Ecto.Migrator.up(Repo, 1, CreateBooks, log: false)
    :ok
  end

  defp columns do
    List.flatten(Repo.query!("select name from pragma_table_info('books')").rows)
  end

  test "rolling back add references/2 fails (turso_core 0.8.1)" do
    :ok = Ecto.Migrator.up(Repo, 2, AddAuthor, log: false)

    assert_raise Sediment.Error,
                 ~r/unknown column "author_id" in foreign key definition/,
                 fn ->
                   Ecto.Migrator.down(Repo, 2, AddAuthor, log: false)
                 end

    assert columns() == ~w(id title author_id)
  end

  test "a down that rebuilds the table removes the column and keeps the rows" do
    :ok = Ecto.Migrator.up(Repo, 2, AddAuthorRebuildDown, log: false)
    Repo.query!("insert into authors (id) values (1)")
    Repo.query!("insert into books (id, title, author_id) values (7, 'x', 1)")

    :ok = Ecto.Migrator.down(Repo, 2, AddAuthorRebuildDown, log: false)
    assert columns() == ~w(id title)
    assert %{rows: [[7, "x"]]} = Repo.query!("select id, title from books")

    :ok = Ecto.Migrator.up(Repo, 2, AddAuthorRebuildDown, log: false)
    assert columns() == ~w(id title author_id)
  end
end
