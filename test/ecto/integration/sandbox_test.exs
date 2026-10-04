defmodule Ecto.Integration.SandboxTest do
  # Ecto.Adapters.SQL.Sandbox the way ecto_sqlite3 users rely on it, in WAL,
  # MVCC and S3 mode.
  use ExUnit.Case, async: false

  import EctoSediment.S3Helpers

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoSediment.DynamicRepo, as: Repo

  @moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()

  defp start_sandboxed(config) do
    pid =
      Repo.start_supervised!(config ++ [pool: Sandbox, pool_size: 4, busy_timeout: 200])

    Repo.query!("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    Sandbox.mode(pid, :manual)
    pid
  end

  defp names,
    do: Repo.query!("SELECT name FROM items ORDER BY name").rows |> List.flatten()

  defp attempt_insert(name) do
    Repo.query!("INSERT INTO items (name) VALUES (?)", [name])
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Runs fun in a new process that uses the same dynamic repo
  defp in_process(repo, fun) do
    Task.async(fn ->
      Repo.put_dynamic_repo(repo)
      fun.()
    end)
  end

  modes = [
    {"WAL", quote(do: [])},
    {"MVCC", quote(do: [journal_mode: :mvcc])},
    {"MVCC with BEGIN CONCURRENT",
     quote(do: [journal_mode: :mvcc, default_transaction_mode: :concurrent])},
    {"S3", quote(do: [s3: s3_opts(unique_prefix("sandbox")), encryption: false])}
  ]

  for {mode, config} <- modes do
    describe mode do
      if mode == "S3", do: @describetag(:s3)

      setup %{tmp_dir: dir} do
        if unquote(mode) == "S3", do: :ok = ensure_bucket()

        repo =
          start_sandboxed([database: Path.join(dir, "sandbox.db")] ++ unquote(config))

        %{repo: repo}
      end

      test "each checkout sees only its own writes, rolled back on checkin", %{
        repo: repo
      } do
        :ok = Sandbox.checkout(repo)
        Repo.query!("INSERT INTO items (name) VALUES ('owner')")
        assert names() == ["owner"]
        :ok = Sandbox.checkin(repo)

        :ok = Sandbox.checkout(repo)
        assert names() == []
        :ok = Sandbox.checkin(repo)
      end

      test "allow/3 shares the owner's transaction with another process", %{repo: repo} do
        :ok = Sandbox.checkout(repo)
        Repo.query!("INSERT INTO items (name) VALUES ('owner')")
        parent = self()

        task =
          in_process(repo, fn ->
            receive do: (:go -> :ok)
            Repo.query!("INSERT INTO items (name) VALUES ('child')")
            names()
          end)

        Sandbox.allow(repo, parent, task.pid)
        send(task.pid, :go)
        assert Task.await(task) == ["child", "owner"]
        assert names() == ["child", "owner"]
      end

      test "shared mode lets any process use the owner's connection", %{repo: repo} do
        :ok = Sandbox.checkout(repo)
        Sandbox.mode(repo, {:shared, self()})
        Repo.query!("INSERT INTO items (name) VALUES ('owner')")

        task =
          in_process(repo, fn -> Repo.query!("SELECT count(*) FROM items").rows end)

        assert Task.await(task) == [[1]]
      end

      test "a process without a checkout is refused in manual mode", %{repo: repo} do
        task =
          in_process(repo, fn ->
            assert_raise DBConnection.OwnershipError, fn -> names() end
          end)

        Task.await(task)
      end

      test "two checkouts writing at the same time", %{repo: repo} do
        parent = self()

        writers =
          for name <- ["a", "b"] do
            in_process(repo, fn ->
              :ok = Sandbox.checkout(repo)
              result = attempt_insert(name)
              send(parent, {:wrote, name})
              receive do: (:check -> :ok)
              {result, names()}
            end)
          end

        for name <- ["a", "b"], do: assert_receive({:wrote, ^name}, 10_000)

        results =
          Enum.map(writers, fn task -> send(task.pid, :check) && Task.await(task) end)

        # One writer at a time in every mode, as with ecto_sqlite3: sandbox
        # transactions use a plain BEGIN, so the second writer gets busy
        assert Enum.any?(results, &match?({:ok, [_]}, &1))
        assert Enum.any?(results, &match?({{:error, "Database busy" <> _}, []}, &1))
      end

      test "unboxed_run/2 escapes the sandbox", %{repo: repo} do
        Sandbox.unboxed_run(repo, fn ->
          Repo.query!("INSERT INTO items (name) VALUES ('committed')")
        end)

        :ok = Sandbox.checkout(repo)
        assert names() == ["committed"]
      end
    end
  end
end
