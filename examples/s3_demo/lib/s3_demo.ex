defmodule S3Demo do
  @moduledoc "Helpers behind the `mix demo.*` tasks."

  import Ecto.Query

  alias S3Demo.{Note, Repo}

  def with_repo(fun) do
    {:ok, result, _} = Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end)
    result
  end

  # Every 10th note waits until it is durable in S3 (sync: true). The others
  # return once they are committed locally; the background uploader makes them
  # durable shortly after (within :max_lag_ms), so a crash can lose the last
  # few of them, never a durable one.
  def write(count) do
    for i <- 1..count do
      sync? = rem(i, 10) == 0
      Repo.insert!(%Note{body: "note #{i} written at #{DateTime.utc_now()}"}, sync: sync?)
      IO.puts(if sync?, do: "committed #{i} (durable)", else: "committed #{i}")
    end
  end

  def show do
    count = Repo.aggregate(Note, :count)
    IO.puts("#{count} notes in the database")

    # A restore is always a prefix of the commits: notes 1..count, no gaps
    if Repo.aggregate(Note, :max, :id) in [nil, count],
      do: IO.puts("no gaps"),
      else: IO.puts("GAPS in the note ids")

    Note
    |> order_by(desc: :id)
    |> limit(3)
    |> select([n], {n.id, n.body})
    |> Repo.all()
    |> Enum.each(fn {id, body} -> IO.puts("  ##{id}: #{body}") end)
  end
end
