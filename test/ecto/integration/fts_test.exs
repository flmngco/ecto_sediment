defmodule Ecto.Integration.FtsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Ecto.Adapters.Sediment.FTS.Query

  alias Ecto.Adapters.Sediment.FTS
  alias EctoSediment.DynamicRepo, as: Repo

  defmodule Article do
    use Ecto.Schema

    schema "articles" do
      field(:title, :string)
      field(:content, :string, source: :body)
    end
  end

  defmodule CreateArticles do
    use Ecto.Migration

    def change do
      create table(:articles) do
        add(:title, :string)
        add(:body, :text)
      end

      create(
        index(:articles, [:title, :body],
          using: :fts,
          options: "weights = 'title=2.0,body=1.0'"
        )
      )
    end
  end

  defp migrate(direction) do
    Ecto.Migrator.run(Repo, [{1, CreateArticles}], direction,
      all: true,
      log: false,
      dynamic_repo: Repo.get_dynamic_repo()
    )
  end

  setup do
    Repo.start_supervised!(database: Temp.path!(), experimental: [:index_method])
    [1] = migrate(:up)

    Repo.insert_all(Article, [
      [title: "Database design", content: "Normal forms and indexes"],
      [title: "Gardening", content: "Tomatoes need sun, not a database"],
      [title: "Cooking", content: "Soup"]
    ])

    :ok
  end

  test "fts_match filters through the index" do
    ids =
      from(a in Article,
        where: fts_match([a.title, a.content], ^"database"),
        order_by: a.id,
        select: a.id
      )
      |> Repo.all()

    assert ids == [1, 2]

    assert [3] =
             Repo.all(
               from(a in Article, where: fts_match(a.title, "cooking"), select: a.id)
             )
  end

  test "fts_highlight marks the matching terms" do
    assert ["<b>Database</b> design"] =
             from(a in Article,
               where: fts_match([a.title, a.content], ^"database") and a.id == 1,
               select: fts_highlight(a.title, "<b>", "</b>", ^"database")
             )
             |> Repo.all()
  end

  test "fts_score with a literal query ranks through the index" do
    assert [{1, top}, {2, other}] =
             from(a in Article,
               where: fts_match([a.title, a.content], "database"),
               select: {a.id, fts_score([a.title, a.content], "database")},
               order_by: [desc: fts_score([a.title, a.content], "database")]
             )
             |> Repo.all()

    assert top > other and other > 0
  end

  test "search/5 ranks with a runtime query and loads structs" do
    assert [
             {%Article{id: 1, content: "Normal forms and indexes"}, top},
             {%Article{id: 2}, other}
           ] =
             FTS.search(Repo, Article, [:title, :content], "database")

    assert top > other and other > 0

    assert [{%Article{id: 1}, _}] =
             FTS.search(Repo, Article, [:title, :content], "database", limit: 1)

    assert [] = FTS.search(Repo, Article, [:title, :content], "unicorn")
  end

  test "new rows are indexed and the migration rolls back" do
    Repo.insert!(%Article{title: "Unicorns", content: "rare"})

    assert [{%Article{title: "Unicorns"}, _}] =
             FTS.search(Repo, Article, [:title, :content], "unicorns")

    assert [1] = migrate(:down)

    assert {:error, %Sediment.Error{message: "no such table: articles"}} =
             Repo.query("SELECT * FROM articles")
  end
end
