defmodule EctoSediment.TortureOracle do
  @moduledoc false
  # Checks what a restore after a kill may contain, given the events a torture
  # writer printed, in order:
  #
  #   {:ack, title, sync?}  a commit returned (sync?: it ran with sync: true)
  #   :flush_begin          a flusher called s3_flush/2...
  #   :flushed              ...and it returned :ok
  #   :fenced               a connection was dropped because the writer was
  #                         fenced: it reconnects and continues from what was
  #                         durable, so earlier non-durable commits may be gone
  #
  # Titles are "<prefix>-w<writer>-<i>": each writer commits i = 1, 2, ... one
  # after the other, and begins commit i right after printing the ack of i - 1.
  #
  # With async durability a kill may lose the last acknowledged commits, but the
  # restored state must be a prefix of the commit order. The log order isn't
  # observable, so the check uses real-time order, which the log respects: if X
  # was acknowledged before a restored commit Y began, X is restored. Commits
  # acknowledged with sync: true, or before a successful flush began, are
  # durable. With durability: :sync every acknowledged commit is durable.

  @doc """
  Returns `{:ok, stats}` or `{:error, reason}`.

  `restored` holds the titles of this round (starting with `prefix`) found
  after the restore. Options: `durability: :async | :sync`.
  """
  def check(events, restored, prefix, opts \\ []) do
    acks =
      for {{:ack, title, sync?}, index} <- Enum.with_index(events),
          do: {title, index, sync?}

    ack_index = Map.new(acks, fn {title, index, _} -> {title, index} end)

    restored =
      restored |> Enum.filter(&String.starts_with?(&1, prefix <> "-")) |> MapSet.new()

    with {:ok, begins} <- begin_indexes(restored, ack_index, prefix),
         :ok <- check_durable(durable(events, acks, opts), restored),
         :ok <- check_prefix(acks, begins, restored, ack_index, fences(events)) do
      acked = MapSet.new(acks, &elem(&1, 0))

      {:ok,
       %{
         acked: MapSet.size(acked),
         restored: MapSet.size(restored),
         lost: acked |> MapSet.difference(restored) |> MapSet.size(),
         sync_acked: Enum.count(acks, &elem(&1, 2)),
         unacknowledged: restored |> MapSet.difference(acked) |> MapSet.size()
       }}
    end
  end

  defp fences(events), do: for({:fenced, index} <- Enum.with_index(events), do: index)

  defp parse(title, prefix) do
    [w, i] = title |> String.replace_prefix(prefix <> "-w", "") |> String.split("-")
    {String.to_integer(w), String.to_integer(i)}
  end

  defp title(prefix, w, i), do: "#{prefix}-w#{w}-#{i}"

  # Commit i of a writer began right after the ack of its commit i - 1 was
  # printed (the first one before any event). So a restored commit whose
  # predecessor wasn't acknowledged is a violation too: only the one commit
  # each writer had in flight may be restored unacknowledged.
  defp begin_indexes(restored, ack_index, prefix) do
    Enum.reduce_while(restored, {:ok, %{}}, fn title, {:ok, acc} ->
      case begin_index(title, ack_index, prefix) do
        {:ok, index} ->
          {:cont, {:ok, Map.put(acc, title, index)}}

        :error ->
          {:halt,
           {:error,
            "#{title} restored, but its writer never acknowledged the commit before it"}}
      end
    end)
  end

  defp begin_index(title, ack_index, prefix) do
    case parse(title, prefix) do
      {_w, 1} -> {:ok, -1}
      {w, i} -> Map.fetch(ack_index, title(prefix, w, i - 1))
    end
  end

  defp durable(events, acks, opts) do
    if Keyword.get(opts, :durability, :async) == :sync do
      MapSet.new(acks, &elem(&1, 0))
    else
      synced = for {title, _, true} <- acks, into: MapSet.new(), do: title
      flushed_upto = flushed_upto(events)
      for({title, index, _} <- acks, index < flushed_upto, into: synced, do: title)
    end
  end

  # Index of the latest :flush_begin followed by a :flushed (one flusher, so
  # they alternate); -1 if none
  defp flushed_upto(events) do
    events
    |> Enum.with_index()
    |> Enum.reduce({-1, nil}, fn
      {:flush_begin, index}, {upto, _} -> {upto, index}
      {:flushed, _}, {_, begin} when is_integer(begin) -> {begin, nil}
      _, acc -> acc
    end)
    |> elem(0)
  end

  defp check_durable(durable, restored) do
    case MapSet.difference(durable, restored) |> Enum.sort() do
      [] -> :ok
      lost -> {:error, "durable commits lost: #{inspect(lost)}"}
    end
  end

  # For each restored commit y, every commit acknowledged before y began is
  # restored, unless the writer was fenced after that acknowledgement and
  # before y committed (it then reconnected and continued from what was
  # durable; y's ack, or any time later if y wasn't acknowledged)
  defp check_prefix(acks, begins, restored, ack_index, fences) do
    holes =
      for {y, begin} <- begins,
          {x, x_ack, _} <- acks,
          x_ack <= begin,
          x not in restored,
          not fenced_between?(fences, x_ack, Map.get(ack_index, y)),
          uniq: true,
          do: {y, x}

    case holes do
      [] ->
        :ok

      holes ->
        {y, _} = Enum.max_by(holes, fn {y, _} -> begins[y] end)
        missing = for({^y, x} <- holes, do: x) |> Enum.sort()

        {:error,
         "not a prefix: #{y} restored, but #{inspect(missing)} acknowledged before it began " <>
           "are missing"}
    end
  end

  defp fenced_between?(fences, x_ack, y_ack),
    do: Enum.any?(fences, &(&1 > x_ack and (is_nil(y_ack) or &1 < y_ack)))
end
