defmodule Ecto.Adapters.Sediment.FTS do
  @moduledoc """
  Full-text search with Turso's FTS indexes.

  Turso's full-text search is built on Tantivy, not SQLite's FTS5. It is an
  experimental Turso feature, enabled per database:

      config :my_app, MyApp.Repo,
        database: "path/to/my/database.db",
        experimental: [:index_method]

  ## Migrations

      create table(:articles) do
        add :title, :string
        add :body, :text
      end

      create index(:articles, [:title, :body], using: :fts)

      # with tokenizer and field weights
      create index(:articles, [:title, :body],
               using: :fts,
               options: "weights = 'title=2.0,body=1.0'"
             )

  `options` is rendered as `WITH (...)`; see Turso's documentation for the
  tokenizers (`default`, `raw`, `simple`, `whitespace`, `ngram`) and weights.

  ## Queries

  `Ecto.Adapters.Sediment.FTS.Query` has `fts_match/2`, `fts_score/2` and
  `fts_highlight/4` for Ecto queries:

      import Ecto.Adapters.Sediment.FTS.Query

      from a in Article,
        where: fts_match([a.title, a.body], ^term),
        select: {a.id, fts_highlight(a.title, "<b>", "</b>", ^term)}

  ## Ranking

  Turso computes `fts_score/2` through the index only when `fts_score` and
  `fts_match` share the same query expression in the SQL (the same `?1`
  parameter, or the same literal). Ecto gives every pinned value its own
  parameter, so in an Ecto query `fts_score` with a pinned term returns
  `0.0`. Use `search/5`, which issues the query with one shared parameter,
  or pass a literal string to both macros.
  """

  @doc """
  Returns the rows of `schema` matching `query` in the full-text index over
  `fields`, best matches first, as `{struct, score}` tuples.

  ## Options

    * `:limit` - maximum number of results, default `20`.

  ## Example

      Ecto.Adapters.Sediment.FTS.search(MyApp.Repo, Article, [:title, :body], "database design")
      #=> [{%Article{...}, 1.37}, {%Article{...}, 0.42}]
  """
  @spec search(Ecto.Repo.t(), module(), [atom()], String.t(), keyword()) :: [
          {struct(), float()}
        ]
  def search(repo, schema, fields, query, opts \\ [])
      when is_list(fields) and is_binary(query) do
    columns = Enum.map(schema.__schema__(:fields), &source(schema, &1))
    fts_columns = Enum.map_join(fields, ", ", &quote_name(source(schema, &1)))
    score_position = length(columns) + 1

    sql =
      "SELECT #{Enum.map_join(columns, ", ", &quote_name/1)}, " <>
        "fts_score(#{fts_columns}, ?1) FROM #{quote_name(schema.__schema__(:source))} " <>
        "WHERE fts_match(#{fts_columns}, ?1) ORDER BY #{score_position} DESC LIMIT ?2"

    %{rows: rows} = repo.query!(sql, [query, Keyword.get(opts, :limit, 20)])

    Enum.map(rows, fn row ->
      {values, [score]} = Enum.split(row, score_position - 1)
      {repo.load(schema, {columns, values}), score}
    end)
  end

  defp source(schema, field), do: schema.__schema__(:field_source, field) |> to_string()

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end

defmodule Ecto.Adapters.Sediment.FTS.Query do
  @moduledoc """
  Query macros for Turso's full-text search functions.

  The first argument is a field or a list of fields covered by an FTS index.
  See `Ecto.Adapters.Sediment.FTS` for setup and the ranking caveat.

      import Ecto.Adapters.Sediment.FTS.Query

      from a in Article,
        where: fts_match([a.title, a.body], ^term),
        select: fts_highlight([a.title, a.body], "<mark>", "</mark>", ^term)
  """

  @doc "True when the fields match the full-text `query`."
  defmacro fts_match(fields, query), do: call("fts_match", List.wrap(fields) ++ [query])

  @doc """
  The BM25 relevance score of the fields for `query` (higher is better).

  Only computed through the index when `fts_match` in the same query uses
  the same expression for `query`; see `Ecto.Adapters.Sediment.FTS`.
  """
  defmacro fts_score(fields, query), do: call("fts_score", List.wrap(fields) ++ [query])

  @doc "The fields' text with terms matching `query` wrapped in `open_tag` and `close_tag`."
  defmacro fts_highlight(fields, open_tag, close_tag, query),
    do: call("fts_highlight", List.wrap(fields) ++ [open_tag, close_tag, query])

  defp call(function, args) do
    sql = function <> "(" <> Enum.map_join(args, ", ", fn _ -> "?" end) <> ")"
    quote do: fragment(unquote(sql), unquote_splicing(args))
  end
end
