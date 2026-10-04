defmodule EctoSediment.TortureHarness do
  @moduledoc false
  # Drives a torture writer child (a port) through one round: waits for its
  # startup marker, collects the events it prints (acknowledged commits,
  # flushes), kills it with SIGKILL and checks that the kill is what ended it.

  import ExUnit.Assertions

  # 128 + SIGKILL, as the port reports a child killed by signal 9
  @killed_status 137
  @recent_lines 20

  @doc """
  Waits for the child's `started` line. Events printed before it (a writer
  can commit before the marker is printed) are kept and returned, newest
  first, with the recent output lines.

  Events are the lines `ack <title>` (`{:ack, title, false}`), `ack-sync
  <title>` (a commit with sync: true, `{:ack, title, true}`), `flush-begin`
  (`:flush_begin`), `flushed` (`:flushed`) and `fenced` (`:fenced`).
  """
  def await_started(port, timeout, events \\ [], recent \\ []) do
    receive do
      {^port, {:data, {:eol, "started"}}} ->
        {events, recent}

      {^port, {:data, {:eol, line}}} ->
        await_started(port, timeout, add_event(events, line), remember(recent, line))

      {^port, {:data, _partial}} ->
        await_started(port, timeout, events, recent)

      {^port, {:exit_status, status}} ->
        flunk("writer exited with #{status} before starting:\n" <> output(recent))
    after
      timeout -> flunk("writer didn't start:\n" <> output(recent))
    end
  end

  @doc """
  Collects events until the child exits, and kills it: after `kill_ms` from
  now (`kill: {:after, ms}`), or `ms` after the first acknowledgement
  (`kill: {:after_ack, ms}`). Returns all events in order; fails if the child
  exits in any other way than by this kill.
  """
  def run(port, os_pid, events, recent, kill: {mode, ms}) do
    ref = make_ref()

    timer =
      if mode == :after or acked(events) != MapSet.new(),
        do: Process.send_after(self(), {:kill, ref}, ms)

    state = %{
      port: port,
      os_pid: os_pid,
      ref: ref,
      timer: timer,
      pending_ms: if(is_nil(timer), do: ms),
      killed?: false,
      recent: recent
    }

    state |> collect(events) |> Enum.reverse()
  end

  @doc "The acknowledged titles among `events`."
  def acked(events),
    do: for({:ack, title, _sync?} <- events, into: MapSet.new(), do: title)

  defp add_event(events, "ack " <> title), do: [{:ack, title, false} | events]
  defp add_event(events, "ack-sync " <> title), do: [{:ack, title, true} | events]
  defp add_event(events, "flush-begin"), do: [:flush_begin | events]
  defp add_event(events, "flushed"), do: [:flushed | events]
  defp add_event(events, "fenced"), do: [:fenced | events]
  defp add_event(events, _line), do: events

  defp collect(%{port: port, ref: ref} = state, events) do
    receive do
      {^port, {:data, {:eol, "ack" <> _ = line}}} ->
        state
        |> arm_on_ack()
        |> remember_line(line)
        |> collect(add_event(events, line))

      {^port, {:data, {:eol, line}}} ->
        if System.get_env("TORTURE_DEBUG"), do: IO.puts("writer: " <> line)
        state |> remember_line(line) |> collect(add_event(events, line))

      {^port, {:data, _partial}} ->
        collect(state, events)

      # No OS pid: the child was gone before we could look; its exit follows.
      {:kill, ^ref} when is_nil(state.os_pid) ->
        collect(state, events)

      {:kill, ^ref} ->
        {_, 0} = System.cmd("kill", ["-9", to_string(state.os_pid)])
        collect(%{state | killed?: true}, events)

      {^port, {:exit_status, status}} ->
        cancel_kill(state)

        unless state.killed? and status == @killed_status do
          flunk(
            "writer exited with #{status} " <>
              if(state.killed?, do: "after our kill", else: "without being killed") <>
              ":\n" <> output(state.recent)
          )
        end

        events
    end
  end

  defp arm_on_ack(%{pending_ms: nil} = state), do: state

  defp arm_on_ack(%{pending_ms: ms, ref: ref} = state),
    do: %{state | timer: Process.send_after(self(), {:kill, ref}, ms), pending_ms: nil}

  # A timer still pending when the child is gone must not fire into a later round.
  defp cancel_kill(%{timer: timer, ref: ref}) do
    if timer, do: Process.cancel_timer(timer)

    receive do
      {:kill, ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  defp remember_line(state, line), do: %{state | recent: remember(state.recent, line)}
  defp remember(recent, line), do: Enum.take([line | recent], @recent_lines)
  defp output(recent), do: recent |> Enum.reverse() |> Enum.join("\n")
end
