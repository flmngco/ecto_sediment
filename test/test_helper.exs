# Every temporary file of a test run (Temp.path!/0, System.tmp_dir!/0, the
# test databases) goes to a per-run directory removed at the end.
# Runs killed before after_suite leave theirs behind: remove those whose OS
# process is gone (Linux, where /proc tells).
if File.dir?("/proc") do
  for dir <- Path.wildcard(Path.join(System.tmp_dir!(), "ecto_sediment_test_*_*")),
      pid = dir |> String.split("_") |> List.last(),
      not File.exists?("/proc/#{pid}"),
      do: File.rm_rf(dir)

  # Per-run ExUnit tmp_dirs (EctoSediment.TestRun.tmp_dir/0)
  for dir <- Path.wildcard("tmp/*/*/run-*"),
      pid = dir |> String.split("-") |> List.last(),
      not File.exists?("/proc/#{pid}"),
      do: File.rm_rf(dir)
end

run_tmp_dir =
  Path.join(System.tmp_dir!(), "ecto_sediment_test_#{System.os_time()}_#{System.pid()}")

File.mkdir_p!(run_tmp_dir)
System.put_env("TMPDIR", run_tmp_dir)

ExUnit.after_suite(fn _ ->
  File.rm_rf(run_tmp_dir)
  Enum.each(Path.wildcard("tmp/*/*/#{EctoSediment.TestRun.tmp_dir()}"), &File.rm_rf/1)
end)

Logger.configure(level: :info)

Application.put_env(:ecto, :primary_key_type, :id)
Application.put_env(:ecto, :async_integration_tests, false)

ecto = Mix.Project.deps_paths()[:ecto]
Code.require_file("#{ecto}/integration_test/support/schemas.exs", __DIR__)

alias Ecto.Integration.TestRepo

Application.put_env(:ecto_sediment, TestRepo,
  adapter: Ecto.Adapters.Sediment,
  database: Path.join(System.tmp_dir!(), "sediment_sandbox_test.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  show_sensitive_data_on_connection_error: true
)

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(TestRepo)
  end
end

{:ok, _} = Ecto.Adapters.Sediment.ensure_all_started(TestRepo.config(), :temporary)

# Load up the repository, start it, and run migrations
_ = Ecto.Adapters.Sediment.storage_down(TestRepo.config())
:ok = Ecto.Adapters.Sediment.storage_up(TestRepo.config())

{:ok, _} = TestRepo.start_link()

:ok = Ecto.Migrator.up(TestRepo, 0, EctoSediment.Integration.Migration, log: false)
Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

Process.flag(:trap_exit, true)

ExUnit.start(exclude: [:s3_fault, :slow, :torture])
