defmodule Ecto.Integration.ObanTest do
  # Oban with Oban.Engines.Lite on ecto_sediment
  use ExUnit.Case, async: false

  import Ecto.Query

  alias EctoSediment.{ObanRepo, ObanWorker}

  modes = [
    {"WAL", quote(do: [])},
    {"MVCC with BEGIN CONCURRENT",
     quote(do: [journal_mode: :mvcc, default_transaction_mode: :concurrent])},
    {"S3",
     quote(
       do: [
         s3:
           EctoSediment.S3Helpers.s3_opts(EctoSediment.S3Helpers.unique_prefix("oban")),
         encryption: false
       ]
     )}
  ]

  defp setup_repo(repo_config) do
    if repo_config[:s3], do: :ok = EctoSediment.S3Helpers.ensure_bucket()

    Application.put_env(
      :ecto_sediment,
      ObanRepo,
      [
        database: Temp.path!(),
        log: false,
        # Oban only knows ecto_sqlite3's adapter module by name
        migrator: Oban.Migrations.SQLite
      ] ++ repo_config
    )

    on_exit(fn -> Application.delete_env(:ecto_sediment, ObanRepo) end)
    start_supervised!(ObanRepo)
    :ok = Ecto.Migrator.up(ObanRepo, 1, EctoSediment.ObanMigration, log: false)

    Process.register(self(), :oban_test)
    :ok
  end

  defp start_oban(opts \\ []) do
    defaults = [
      repo: ObanRepo,
      engine: Oban.Engines.Lite,
      queues: [default: 5],
      stage_interval: 50
    ]

    start_supervised!({Oban, Keyword.merge(defaults, opts)})
  end

  defp job(id, args \\ %{}, opts \\ []),
    do: ObanWorker.new(Map.merge(%{"to" => "oban_test", "id" => id}, args), opts)

  defp states do
    ObanRepo.all(from(j in Oban.Job, select: {j.args["id"], j.state}, order_by: j.id))
  end

  for {mode, config} <- modes do
    describe mode do
      if mode == "S3", do: @describetag(:s3)
      setup do: setup_repo(unquote(config))

      test "inserted jobs run" do
        start_oban()
        {:ok, _} = Oban.insert(job(1))
        [_, _] = Oban.insert_all([job(2), job(3)])

        for id <- 1..3, do: assert_receive({:performed, ^id, 1}, 5_000)
        Process.sleep(100)
        assert states() == [{1, "completed"}, {2, "completed"}, {3, "completed"}]
      end

      test "failing jobs are retried until they succeed" do
        start_oban()
        {:ok, _} = Oban.insert(job(1, %{"fail" => 2}))

        assert_receive {:performed, 1, 1}, 5_000
        assert_receive {:performed, 1, 2}, 5_000
        assert_receive {:performed, 1, 3}, 5_000
        Process.sleep(100)

        assert [%Oban.Job{state: "completed", attempt: 3, errors: [_, _]}] =
                 ObanRepo.all(Oban.Job)
      end

      test "jobs that keep failing are discarded after max_attempts" do
        start_oban()
        {:ok, _} = Oban.insert(job(1, %{"fail" => 10}))

        for attempt <- 1..3, do: assert_receive({:performed, 1, ^attempt}, 5_000)
        refute_receive {:performed, 1, 4}, 300
        assert states() == [{1, "discarded"}]
      end

      test "scheduled jobs wait for their time" do
        start_oban()
        {:ok, _} = Oban.insert(job(1, %{}, schedule_in: 1))
        refute_receive {:performed, 1, _}, 500
        assert_receive {:performed, 1, 1}, 5_000
      end

      test "unique jobs are inserted once" do
        start_oban(queues: false)
        {:ok, %{conflict?: false}} = Oban.insert(job(1, %{}, unique: [period: 60]))
        {:ok, %{conflict?: true}} = Oban.insert(job(1, %{}, unique: [period: 60]))
        {:ok, %{conflict?: false}} = Oban.insert(job(2, %{}, unique: [period: 60]))
        assert states() == [{1, "available"}, {2, "available"}]
      end

      test "two Oban instances on the same repo run every job exactly once" do
        start_oban(name: ObanA, queues: [default: 10])
        start_oban(name: ObanB, queues: [default: 10])

        1..200
        |> Enum.map(&job/1)
        |> Enum.chunk_every(50)
        |> Enum.each(&Oban.insert_all(ObanA, &1))

        performed =
          for _ <- 1..200 do
            assert_receive {:performed, id, 1}, 20_000
            id
          end

        assert Enum.sort(performed) == Enum.to_list(1..200)
        refute_receive {:performed, _, _}, 500
      end

      # The cron plugin fires on minute boundaries: run with --include slow
      @tag :slow
      @tag timeout: 120_000
      test "the cron plugin inserts scheduled jobs" do
        crontab = [
          {"* * * * *", ObanWorker, args: %{"to" => "oban_test", "id" => "cron"}}
        ]

        start_oban(plugins: [{Oban.Plugins.Cron, crontab: crontab}])
        assert_receive {:performed, "cron", 1}, 70_000
      end

      test "jobs can be cancelled" do
        start_oban(queues: false)
        {:ok, %{id: id}} = Oban.insert(job(1))
        :ok = Oban.cancel_job(id)
        assert states() == [{1, "cancelled"}]
      end

      test "the pruner deletes old completed jobs" do
        start_oban(plugins: [{Oban.Plugins.Pruner, interval: 100, max_age: 1}])
        {:ok, _} = Oban.insert(job(1))
        assert_receive {:performed, 1, 1}, 5_000
        Process.sleep(1_500)

        assert Enum.any?(1..30, fn _ ->
                 states() == [] or (Process.sleep(100) && false)
               end)
      end
    end
  end
end
