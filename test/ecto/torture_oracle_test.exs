defmodule EctoSediment.TortureOracleTest do
  use ExUnit.Case, async: true

  alias EctoSediment.TortureOracle, as: Oracle

  defp ack(title, sync? \\ false), do: {:ack, "r1-" <> title, sync?}
  defp restored(titles), do: Enum.map(titles, &("r1-" <> &1))

  # w1 and w2 interleaved: w1-1, w2-1, w1-2 (sync), flush, w2-2, w1-3
  defp events do
    [
      ack("w1-1"),
      ack("w2-1"),
      ack("w1-2", true),
      :flush_begin,
      ack("w2-2"),
      :flushed,
      ack("w1-3")
    ]
  end

  test "everything acknowledged, restored" do
    assert {:ok, %{acked: 5, lost: 0, sync_acked: 1}} =
             Oracle.check(events(), restored(~w(w1-1 w2-1 w1-2 w2-2 w1-3)), "r1")
  end

  test "async: losing the commits after the last durable one is fine" do
    # w1-2 is sync-acked and flush covers w1-1, w2-1, w1-2
    assert {:ok, %{lost: 2}} =
             Oracle.check(events(), restored(~w(w1-1 w2-1 w1-2)), "r1")
  end

  test "sync durability: every acknowledged commit must be restored" do
    assert {:error, "durable commits lost: " <> _} =
             Oracle.check(events(), restored(~w(w1-1 w2-1 w1-2)), "r1",
               durability: :sync
             )
  end

  test "a sync-acknowledged commit may not be lost" do
    events = [ack("w1-1"), ack("w1-2", true), ack("w1-3")]

    assert {:error, "durable commits lost: [\"r1-w1-2\"]"} =
             Oracle.check(events, restored(~w(w1-1)), "r1")
  end

  test "a commit acknowledged before a successful flush may not be lost" do
    events = [ack("w1-1"), ack("w2-1"), :flush_begin, ack("w1-2"), :flushed]

    assert {:error, "durable commits lost: [\"r1-w2-1\"]"} =
             Oracle.check(events, restored(~w(w1-1)), "r1")

    # A flush that didn't return :ok proves nothing
    events = [ack("w1-1"), ack("w2-1"), :flush_begin, ack("w1-2")]
    assert {:ok, _} = Oracle.check(events, restored(~w(w1-1)), "r1")
  end

  test "a hole before a restored commit is a violation" do
    # w2-2 began (after w2-1's ack) once w1-2 was acknowledged, but w1-2 is missing
    events = [ack("w1-1"), ack("w1-2"), ack("w2-1"), ack("w2-2")]

    assert {:error, "not a prefix: r1-w2-2 restored, but [\"r1-w1-2\"]" <> _} =
             Oracle.check(events, restored(~w(w1-1 w2-1 w2-2)), "r1")

    # Concurrent commits may land in either order: w1-2 was acknowledged after
    # w2-2 began, so w2-2 without w1-2 is a valid prefix
    events = [ack("w1-1"), ack("w2-1"), ack("w2-2"), ack("w1-2")]
    assert {:ok, _} = Oracle.check(events, restored(~w(w1-1 w2-1 w2-2)), "r1")
  end

  test "within a writer, a gap is a violation" do
    events = [ack("w1-1"), ack("w1-2"), ack("w1-3")]

    assert {:error, "not a prefix: " <> _} =
             Oracle.check(events, restored(~w(w1-1 w1-3)), "r1")
  end

  test "the one commit in flight per writer may be restored unacknowledged" do
    events = [ack("w1-1"), ack("w2-1")]

    assert {:ok, %{unacknowledged: 2}} =
             Oracle.check(events, restored(~w(w1-1 w1-2 w2-1 w2-2)), "r1")

    assert {:error, "r1-w1-4 restored, but its writer never acknowledged" <> _} =
             Oracle.check(
               [ack("w1-1"), ack("w1-2")],
               restored(~w(w1-1 w1-2 w1-3 w1-4)),
               "r1"
             )
  end

  test "rows of other rounds are ignored" do
    assert {:ok, %{restored: 1}} =
             Oracle.check([ack("w1-1")], ["r0-w1-7", "r1-w1-1"], "r1")
  end

  test "across a fence, earlier non-durable commits may be missing" do
    events = [ack("w1-1"), ack("w1-2"), :fenced, ack("w1-3")]
    assert {:ok, _} = Oracle.check(events, restored(~w(w1-1 w1-3)), "r1")

    # a fence after w1-3 committed explains nothing
    events = [ack("w1-1"), ack("w1-2"), ack("w1-3"), :fenced]

    assert {:error, "not a prefix: " <> _} =
             Oracle.check(events, restored(~w(w1-1 w1-3)), "r1")
  end
end
