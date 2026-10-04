# Writes forever from several concurrent processes to an S3-backed repo and
# prints "ack <value>" after each acknowledged commit ("ack-sync <value>" for
# every fifth one, made with sync: true), until it is killed. A flusher prints
# "flush-begin" before each s3_flush/2 and "flushed" when it returned :ok;
# "fenced" when a connection was dropped because the writer was fenced.
# Usage: mix run --no-compile --no-deps-check --no-start s3_torture_writer.exs <config.term> <writers> <round>

defmodule TortureWriter do
  alias EctoSediment.DynamicRepo, as: Repo
  alias EctoSediment.S3App.Post

  # One row per transaction, some with a second statement. Concurrent inserts
  # into the AUTOINCREMENT table can conflict; like an application, retry.
  def commit(title, i, sync?) do
    Repo.transaction(
      fn ->
        Repo.insert!(%Post{title: title, views: i})
        if rem(i, 3) == 0, do: Repo.query!("SELECT count(*) FROM posts")
      end,
      sync: sync?
    )
  rescue
    error in Sediment.Error ->
      if error.message =~ "conflict",
        do: commit(title, i, sync?),
        else: reraise(error, __STACKTRACE__)
  end

  def run(pid, round, w) do
    Repo.put_dynamic_repo(pid)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.each(fn i ->
      title = "r#{round}-w#{w}-#{i}"
      sync? = rem(i, 5) == 0
      {:ok, _} = commit(title, i, sync?)
      IO.puts(if(sync?, do: "ack-sync ", else: "ack ") <> title)
    end)
  end

  def flush(pid) do
    Process.sleep(300)
    IO.puts("flush-begin")
    if Ecto.Adapters.Sediment.s3_flush(pid, 5_000) == :ok, do: IO.puts("flushed")
    flush(pid)
  end
end

[config_path, writers, round] = System.argv()
config = config_path |> File.read!() |> :erlang.binary_to_term()

{:ok, _} = Application.ensure_all_started(:ecto_sql)

# A fenced writer reconnects and continues from what was durable
:telemetry.attach(
  "torture-fenced",
  [:sediment, :connection, :disconnect],
  fn
    _event, _measurements, %{reason: :fenced}, _ -> IO.puts("fenced")
    _event, _measurements, _meta, _ -> :ok
  end,
  nil
)

{:ok, pid} = EctoSediment.DynamicRepo.start_link([name: nil, log: false] ++ config)

for w <- 1..String.to_integer(writers),
    do: spawn_link(fn -> TortureWriter.run(pid, round, w) end)

spawn_link(fn -> TortureWriter.flush(pid) end)

IO.puts("started")
Process.sleep(:infinity)
