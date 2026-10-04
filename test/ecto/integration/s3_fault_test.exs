defmodule Ecto.Integration.S3FaultTest do
  # S3 outages against an S3-backed repo, using a SeaweedFS container of its
  # own that is paused mid-write. Needs docker; run with --only s3_fault.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EctoSediment.DynamicRepo, as: Repo

  @moduletag :s3_fault
  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()
  @moduletag timeout: 180_000

  @container "ecto-sediment-s3-fault-#{System.os_time()}"

  setup_all do
    port = 20_000 + :rand.uniform(10_000)

    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--name",
        @container,
        "-p",
        "127.0.0.1:#{port}:8333",
        # pinned: newer images refuse anonymous S3 requests (403) by default
        "chrislusf/seaweedfs:4.48",
        "server",
        "-s3"
      ])

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", @container], stderr_to_stdout: true)
    end)

    endpoint = "http://127.0.0.1:#{port}"
    # Ready once a bucket can be created and an object written into it
    true = wait_until(fn -> put(port, "/fault") and put(port, "/fault/ready") end, 120)
    %{endpoint: endpoint}
  end

  defp put(port, path) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false]) do
      {:ok, socket} ->
        :ok =
          :gen_tcp.send(
            socket,
            "PUT #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n" <>
              "Connection: close\r\n\r\nok"
          )

        result = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)

        match?({:ok, "HTTP/1.1 200" <> _}, result) or
          match?({:ok, "HTTP/1.1 409" <> _}, result)

      {:error, _} ->
        false
    end
  end

  defp wait_until(fun, attempts) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(500) && wait_until(fun, attempts - 1)
    end
  end

  defp docker(command), do: {_, 0} = System.cmd("docker", [command, @container])

  defp insert(value, opts \\ []) do
    Repo.query!("INSERT INTO t VALUES (?)", [value], opts)
    :ok
  rescue
    error in Sediment.Error -> {:error, error.message}
    # while the pool reconnects after the outage
    error in DBConnection.ConnectionError -> {:error, error.message}
  end

  # Inserts until one succeeds or the deadline passes; returns all attempts
  defp recover(deadline, i, attempts, opts \\ []) do
    value = "recovering-#{i}"
    attempts = attempts ++ [{value, insert(value, opts)}]

    cond do
      match?({_, :ok}, List.last(attempts)) -> attempts
      System.monotonic_time(:millisecond) > deadline -> attempts
      true -> Process.sleep(200) && recover(deadline, i + 1, attempts, opts)
    end
  end

  defp values, do: Repo.query!("SELECT v FROM t ORDER BY rowid").rows |> List.flatten()

  defp s3_config(ctx, durability) do
    [
      bucket: "fault",
      prefix: "outage-#{System.unique_integer([:positive])}",
      endpoint: ctx.endpoint,
      access_key_id: "any",
      secret_access_key: "any",
      owner: "node",
      lease_ttl_ms: 15_000,
      request_timeout_ms: 1_000,
      max_retries: 0,
      durability: durability
    ]
  end

  test "durability: :sync: commits fail during an outage and the writer recovers after it",
       ctx do
    s3 = s3_config(ctx, :sync)

    config = [
      s3: s3,
      encryption: false,
      pool_size: 2,
      backoff_min: 100,
      backoff_max: 500
    ]

    pid = Repo.start_supervised!([database: Path.join(ctx.tmp_dir, "a.db")] ++ config)
    assert wait_until(fn -> match?({:ok, _}, Repo.query("SELECT 1")) end, 40)
    Repo.query!("CREATE TABLE t (v TEXT)")
    :ok = insert("before")

    docker("pause")

    assert {:error, "s3" <> _} = insert("ambiguous")

    assert_raise Sediment.Error, ~r/s3/, fn ->
      Repo.transaction(fn ->
        Repo.query!("INSERT INTO t VALUES ('tx-1')")
        Repo.query!("INSERT INTO t VALUES ('tx-2')")
      end)
    end

    # The local copy never shows the failed transaction (reads may also be
    # refused once the writer notices it can't renew its lease)
    try do
      refute "tx-1" in values()
    rescue
      error in Sediment.Error -> assert error.message =~ "fenced"
    end

    Process.sleep(3_000)
    docker("unpause")

    # The writer may be fenced for a moment (its lease expired), then its
    # connections reconnect, restore from S3 and accept writes again. How long
    # that takes depends on the machine; it must happen eventually.
    recovery = recover(System.monotonic_time(:millisecond) + 60_000, 1, [])

    assert {_, :ok} = List.last(recovery), "the writer didn't recover within 60 s"

    # Once recovered, it keeps working
    steady = for i <- 1..10, do: {"after-#{i}", insert("after-#{i}")}
    assert Enum.all?(steady, &match?({_, :ok}, &1)), inspect(steady)

    results = recovery ++ steady
    acknowledged = for {value, :ok} <- results, do: value
    view = values()
    Supervisor.stop(pid)

    Repo.start_supervised!([database: Path.join(ctx.tmp_dir, "fresh.db")] ++ config)
    restored = values()

    # Everything acknowledged is durable. Commits reported as failed during the
    # outage are "ambiguous": their upload may have landed after all (the paused
    # server still received it), so they may be restored, as documented, but a
    # transaction is restored completely or not at all.
    assert restored == view
    assert "before" in restored
    assert Enum.all?(acknowledged, &(&1 in restored))
    assert "tx-1" in restored == "tx-2" in restored

    for {value, result} <- results, result != :ok do
      refute value in restored, "#{value} failed after the outage but was restored"
    end

    assert restored -- ["ambiguous", "tx-1", "tx-2"] == ["before" | acknowledged]
  end

  # Async durability: commits during the outage may be accepted locally, until
  # backpressure or the uploader giving up stops the writer; those never made
  # durable are lost. What survives is a prefix of the commits, and every
  # commit made with sync: true.
  test "async durability: an outage loses at most the commits not yet durable", ctx do
    config = [
      s3: s3_config(ctx, :async),
      encryption: false,
      pool_size: 2,
      backoff_min: 100,
      backoff_max: 500
    ]

    pid = Repo.start_supervised!([database: Path.join(ctx.tmp_dir, "a.db")] ++ config)
    assert wait_until(fn -> match?({:ok, _}, Repo.query("SELECT 1")) end, 40)
    Repo.query!("CREATE TABLE t (v TEXT)", [], sync: true)
    :ok = insert("before", sync: true)

    docker("pause")

    {outage, _log} =
      with_log(fn ->
        for i <- 1..15, do: {"outage-#{i}", outage_insert("outage-#{i}")}
      end)

    docker("unpause")

    {recovery, _log} =
      with_log(fn ->
        recover(System.monotonic_time(:millisecond) + 60_000, 1, [], sync: true)
      end)

    assert {_, :ok} = List.last(recovery), "the writer didn't recover within 60 s"
    steady = for i <- 1..5, do: {"after-#{i}", insert("after-#{i}", sync: true)}
    assert Enum.all?(steady, &match?({_, :ok}, &1)), inspect(steady)

    view = values()
    Supervisor.stop(pid)
    Repo.start_supervised!([database: Path.join(ctx.tmp_dir, "fresh.db")] ++ config)
    restored = values()

    synced = for {value, :ok} <- recovery ++ steady, do: value
    outage_acked = for {value, :ok} <- outage, do: value

    assert restored == view
    # "before", then a prefix of the commits accepted during the outage, then
    # everything acknowledged with sync: true after it
    assert ["before" | rest] = restored
    {from_outage, after_outage} = Enum.split(rest, length(rest) - length(synced))
    assert after_outage == synced
    assert from_outage == Enum.take(outage_acked, length(from_outage))
  end

  # Each insert gets a short timeout: once the upload queue is full, commits
  # wait for it
  defp outage_insert(value) do
    insert(value, timeout: 2_000)
  end
end
