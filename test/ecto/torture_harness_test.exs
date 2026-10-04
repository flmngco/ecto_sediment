defmodule EctoSediment.TortureHarnessTest do
  # The crash-torture test's harness, driven by fake writers (sh scripts).
  use ExUnit.Case, async: true

  alias EctoSediment.TortureHarness

  defp child(script) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 1_000},
        args: ["-c", script]
      ])

    # nil once a quick child has exited already; it then needs no kill
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    {port, os_pid}
  end

  test "acknowledgements printed before the startup marker are kept" do
    {port, os_pid} =
      child("echo 'ack r1-w1-1'; echo started; echo 'ack r1-w1-2'; exec sleep 30")

    {events, recent} = TortureHarness.await_started(port, 5_000)
    assert MapSet.member?(TortureHarness.acked(events), "r1-w1-1")

    events = TortureHarness.run(port, os_pid, events, recent, kill: {:after, 200})
    assert TortureHarness.acked(events) == MapSet.new(["r1-w1-1", "r1-w1-2"])
  end

  test "events come back in order: sync acknowledgements and flushes included" do
    {port, os_pid} =
      child(
        "echo 'ack r1-w1-1'; echo started; echo flush-begin; echo 'ack-sync r1-w1-2'; " <>
          "echo flushed; echo 'other output'; exec sleep 30"
      )

    {events, recent} = TortureHarness.await_started(port, 5_000)

    assert TortureHarness.run(port, os_pid, events, recent, kill: {:after, 200}) == [
             {:ack, "r1-w1-1", false},
             :flush_begin,
             {:ack, "r1-w1-2", true},
             :flushed
           ]
  end

  test "a writer that exits on its own fails the round instead of passing as a kill" do
    {port, os_pid} = child("echo started; echo 'ack r1-w1-1'; exit 23")
    {events, recent} = TortureHarness.await_started(port, 5_000)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        TortureHarness.run(port, os_pid, events, recent, kill: {:after, 5_000})
      end

    assert error.message =~ "exited with 23 without being killed"
    assert error.message =~ "ack r1-w1-1"
    # its kill timer is gone, so it can't hit a later round
    refute_received {:kill, _}
  end

  test "an acknowledgement during startup arms a kill-after-ack round" do
    {port, os_pid} = child("echo 'ack r2-w1-1'; echo started; exec sleep 30")
    {events, recent} = TortureHarness.await_started(port, 5_000)
    started = System.monotonic_time(:millisecond)

    assert TortureHarness.run(port, os_pid, events, recent, kill: {:after_ack, 100}) ==
             [{:ack, "r2-w1-1", false}]

    assert System.monotonic_time(:millisecond) - started < 5_000
  end
end
