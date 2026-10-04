defmodule EctoSediment.S3App do
  @moduledoc false
  # Schema and migrations used by the S3 disaster recovery tests.

  defmodule Post do
    @moduledoc false
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:views, :integer, default: 0)
      field(:tag, :string)
      timestamps()
    end
  end

  defmodule CreatePosts do
    @moduledoc false
    use Ecto.Migration

    def change do
      create table(:posts) do
        add(:title, :string, null: false)
        add(:views, :integer, default: 0)
        timestamps()
      end

      create(unique_index(:posts, [:title]))
    end
  end

  defmodule AddTag do
    @moduledoc false
    use Ecto.Migration

    def change do
      alter table(:posts) do
        add(:tag, :string)
      end

      create(index(:posts, [:tag]))
    end
  end

  @migrations [{1, CreatePosts}, {2, AddTag}]

  def migrate(repo, pid) do
    Ecto.Migrator.run(repo, @migrations, :up, all: true, log: false, dynamic_repo: pid)
  end
end
