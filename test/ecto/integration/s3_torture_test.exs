defmodule Ecto.Integration.S3TortureTest do
  # Kills a writer VM (several concurrent Ecto writers) with SIGKILL at random
  # points, then restores on a fresh node and checks the result with
  # EctoSediment.TortureOracle. With durability: :async (TORTURE_DURABILITY=async,
  # the default here) the restored state is a prefix of the commit order
  # holding every commit acknowledged with sync: true or before a successful
  # flush; with TORTURE_DURABILITY=sync every acknowledged commit. Run with
  # --only torture; TORTURE_ROUNDS sets the rounds.
  use ExUnit.Case, async: false

  import Ecto.Query
  import EctoSediment.S3Helpers

  alias EctoSediment.DynamicRepo, as: Repo
  alias EctoSediment.S3App
  alias EctoSediment.S3App.Post
  alias EctoSediment.TortureHarness
  alias EctoSediment.TortureOracle

  @moduletag :s3
  @moduletag :torture
  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()
  @moduletag timeout: :infinity

  @writers 4

  test "kill -9 at random points loses nothing durable and leaves a prefix", ctx do
    rounds = String.to_integer(System.get_env("TORTURE_ROUNDS", "10"))
    durability = String.to_existing_atom(System.get_env("TORTURE_DURABILITY", "async"))
    :ok = ensure_bucket()

    # Small checkpoint threshold: kills often land during checkpoints and
    # snapshot uploads
    # S3 goes through a proxy whose added latency changes every round
    %URI{host: host, port: port} = URI.parse(endpoint())

    proxy =
      start_supervised!(
        {EctoSediment.LatencyProxy, upstream: {String.to_charlist(host), port}}
      )

    proxy_endpoint = "http://127.0.0.1:#{EctoSediment.LatencyProxy.port(proxy)}"

    s3 =
      s3_opts(
        unique_prefix("torture"),
        "torturer",
        checkpoint_threshold: 16_384,
        durability: durability
      )
      |> Keyword.put(:endpoint, proxy_endpoint)

    base = [
      s3: s3,
      encryption: false,
      pool_size: @writers,
      default_transaction_mode: :concurrent
    ]

    node = fn name ->
      Keyword.put(base, :database, Path.join(ctx.tmp_dir, "#{name}.db"))
    end

    pid = Repo.start_supervised!(node.("setup"))
    S3App.migrate(Repo, pid)
    Supervisor.stop(pid)

    Enum.reduce(1..rounds, MapSet.new(), fn round, durable ->
      config_path = Path.join(ctx.tmp_dir, "config-#{round}.term")
      File.write!(config_path, :erlang.term_to_binary(node.("writer-#{round}")))

      EctoSediment.LatencyProxy.set_delay(proxy, Enum.random([0, 0, 5, 20, 50]))
      # Odd rounds may kill the writer while it is still restoring at startup;
      # even rounds wait for its first acknowledged commit
      kill_after_ack? = rem(round, 2) == 0

      # A third of the rounds also cut S3 off for a moment (open connections
      # dropped, new ones refused), so uploads fail and are retried
      outage = if :rand.uniform(3) == 1, do: Task.async(fn -> outage(proxy) end)

      events =
        run_and_kill(config_path, round, 500 + :rand.uniform(3_000), kill_after_ack?)

      if outage, do: Task.await(outage, 10_000)
      EctoSediment.LatencyProxy.set_delay(proxy, 0)

      if kill_after_ack?,
        do:
          assert(
            TortureHarness.acked(events) != MapSet.new(),
            "round #{round}: nothing acknowledged"
          )

      pid = Repo.start_supervised!(node.("check-#{round}"))
      restored = Repo.all(from(p in Post, select: p.title)) |> MapSet.new()
      Supervisor.stop(pid)

      # What an earlier check restored was durable; it stays
      missing = MapSet.difference(durable, restored)

      assert MapSet.size(missing) == 0,
             "round #{round}: durable rows lost: #{inspect(missing)}"

      case TortureOracle.check(events, restored, "r#{round}", durability: durability) do
        {:ok, stats} ->
          if System.get_env("TORTURE_DEBUG"),
            do: IO.puts("round #{round} (#{durability}): #{inspect(stats)}")

        {:error, reason} ->
          flunk("round #{round} (#{durability}): #{reason}")
      end

      # The next writer continues from what is durable
      restored
    end)
  end

  defp outage(proxy) do
    Process.sleep(:rand.uniform(2_000))
    EctoSediment.LatencyProxy.set_down(proxy, true)
    Process.sleep(300 + :rand.uniform(1_200))
    EctoSediment.LatencyProxy.set_down(proxy, false)
  end

  defp run_and_kill(config_path, round, run_ms, kill_after_ack?) do
    mix = System.find_executable("mix")

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 1_000},
        args: [
          "run",
          "--no-compile",
          "--no-deps-check",
          "--no-start",
          Path.expand("../../support/scripts/s3_torture_writer.exs", __DIR__),
          config_path,
          to_string(@writers),
          to_string(round)
        ],
        env: [{~c"MIX_ENV", ~c"test"}]
      ])

    # nil if the writer already exited; the harness then reports that exit
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    {events, recent} = TortureHarness.await_started(port, 120_000)
    kill = if kill_after_ack?, do: {:after_ack, run_ms}, else: {:after, run_ms}
    TortureHarness.run(port, os_pid, events, recent, kill: kill)
  end
end
