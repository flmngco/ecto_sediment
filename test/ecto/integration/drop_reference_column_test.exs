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

      create table(:reviews) do
        add(:book_id, references(:books, on_delete: :delete_all))
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

  # The migrating guide's recipe
  defmodule AddAuthorRebuildDown do
    use Ecto.Migration

    @disable_ddl_transaction true

    def up, do: AddAuthor.change()

    def down do
      repo().checkout(fn ->
        repo().query!("PRAGMA foreign_keys = OFF")

        try do
          repo().transaction(fn ->
            create table(:books_new) do
              add(:title, :string)
            end

            execute("INSERT INTO books_new (id, title) SELECT id, title FROM books")
            drop(table(:books))
            rename(table(:books_new), to: table(:books))
            flush()
          end)
        after
          repo().query!("PRAGMA foreign_keys = ON")
        end
      end)
    end
  end

  # The same rebuild in the migration's transaction, with foreign keys on
  defmodule AddAuthorRebuildDownInTransaction do
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

  setup context do
    Repo.start_supervised!(
      database: Temp.path!(),
      pool_size: 3,
      journal_mode: context[:journal_mode] || :wal
    )

    :ok = Ecto.Migrator.up(Repo, 1, CreateBooks, log: false)
    :ok
  end

  defp insert_rows do
    Repo.query!("insert into authors (id) values (1)")
    Repo.query!("insert into books (id, title, author_id) values (7, 'x', 1)")
    Repo.query!("insert into reviews (id, book_id) values (3, 7)")
  end

  # every connection of the pool at once
  defp foreign_keys_per_connection do
    parent = self()
    repo = Repo.get_dynamic_repo()

    tasks =
      for _ <- 1..3 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.checkout(fn ->
            send(parent, :checked_out)
            receive do: (:go -> :ok)
            Repo.query!("PRAGMA foreign_keys").rows
          end)
        end)
      end

    for _ <- tasks, do: assert_receive(:checked_out)
    for task <- tasks, do: send(task.pid, :go)
    Enum.map(tasks, &Task.await/1)
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

  for journal_mode <- [:wal, :mvcc] do
    @tag journal_mode: journal_mode
    test "a down that rebuilds the table on one connection, foreign keys off (#{journal_mode})" do
      :ok = Ecto.Migrator.up(Repo, 2, AddAuthorRebuildDown, log: false)
      insert_rows()

      :ok = Ecto.Migrator.down(Repo, 2, AddAuthorRebuildDown, log: false)
      assert columns() == ~w(id title)
      assert %{rows: [[7, "x"]]} = Repo.query!("select id, title from books")
      # the referencing rows stay, and still match
      assert %{rows: [[3, 7]]} = Repo.query!("select id, book_id from reviews")
      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
      assert foreign_keys_per_connection() == [[[1]], [[1]], [[1]]]

      :ok = Ecto.Migrator.up(Repo, 2, AddAuthorRebuildDown, log: false)
      assert columns() == ~w(id title author_id)
    end
  end

  test "the rebuild in the migration's transaction runs the ON DELETE actions" do
    :ok = Ecto.Migrator.up(Repo, 2, AddAuthorRebuildDownInTransaction, log: false)
    insert_rows()

    :ok = Ecto.Migrator.down(Repo, 2, AddAuthorRebuildDownInTransaction, log: false)
    assert columns() == ~w(id title)
    # DROP TABLE deleted the reviews (on_delete: :delete_all)
    assert %{rows: []} = Repo.query!("select * from reviews")
  end
end
