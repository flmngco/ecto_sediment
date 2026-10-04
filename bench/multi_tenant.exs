# Resources of many open tenant databases, with the reference code of
# guides/multi_tenant.md (evaluated from the guide):
#   mix run multi_tenant.exs local 1000
#   mix run multi_tenant.exs s3 1000     # SeaweedFS on 127.0.0.1:8333 (S3_ENDPOINT, S3_BUCKET)
# Prints the time to open the tenants, RSS, open file descriptors, OS threads
# and BEAM memory once they are open, the S3 requests of the idle tenants over
# IDLE_S (default 60) seconds, and what is left after stopping them all; ROUNDS
# repeats the open/stop cycle in the same VM (to tell allocator retention from
# leaks).
[mode, count] = System.argv()
count = String.to_integer(count)
idle_s = String.to_integer(System.get_env("IDLE_S", "60"))
Logger.configure(level: :warning)

defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Sediment
end

guide = File.read!(Path.expand("../guides/multi_tenant.md", __DIR__))
[_, code] = Regex.run(~r/evaluates this block -->\n```elixir\n(.*?)\n```/s, guide)
Code.compile_string(code, "guides/multi_tenant.md")

dir = Path.join(System.tmp_dir!(), "multi_tenant_bench_#{System.unique_integer([:positive])}")
migrations = Path.join(dir, "migrations")
File.mkdir_p!(migrations)

File.write!(Path.join(migrations, "1_create_notes.exs"), """
defmodule MyApp.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes, primary_key: false) do
      add :id, :integer, primary_key: true
      add :body, :text
    end
  end
end
""")

endpoint = System.get_env("S3_ENDPOINT", "http://127.0.0.1:8333")
bucket = System.get_env("S3_BUCKET", "ecto-bench")
base = "multi-tenant-bench/#{System.os_time(:second)}"

if mode == "s3" do
  # SeaweedFS creates a bucket on an unsigned PUT
  System.cmd("curl", ["-s", "-o", "/dev/null", "-X", "PUT", "#{endpoint}/#{bucket}"])
end

repo_config = fn tenant_id ->
  config = [database: Path.join(dir, "#{tenant_id}.db"), pool_size: 1]

  case mode do
    "local" ->
      config

    "s3" ->
      config ++
        [
          encryption: false,
          s3: [
            bucket: bucket,
            endpoint: endpoint,
            prefix: "#{base}/#{tenant_id}/",
            access_key_id: "any",
            secret_access_key: "any",
            owner: "bench"
          ]
        ]
  end
end

Application.put_env(:my_app, MyApp.Tenants,
  repo: repo_config,
  migrations_path: migrations,
  idle_after: :timer.hours(1)
)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = MyApp.Tenants.start_link([])

stats = fn ->
  status = File.read!("/proc/self/status")

  field = fn name ->
    Regex.run(~r/#{name}:\s+(\d+)/, status) |> List.last() |> String.to_integer()
  end

  %{
    rss_mb: div(field.("VmRSS"), 1024),
    threads: field.("Threads"),
    fds: length(File.ls!("/proc/self/fd")),
    beam_mb: div(:erlang.memory(:total), 1024 * 1024)
  }
end

s3_requests = fn ->
  for {_op, %{count: n}} <- Sediment.S3.request_counts(), reduce: 0, do: (sum -> sum + n)
end

rounds = String.to_integer(System.get_env("ROUNDS", "1"))

for round <- 1..rounds do
  IO.puts("round #{round}")
  before = stats.()
  IO.puts("#{mode}, #{count} tenants, pool_size 1")
  IO.puts("before:     #{inspect(before)}")

  {us, _} =
    :timer.tc(fn ->
      1..count
      |> Task.async_stream(
        fn n ->
          MyApp.Tenants.with_tenant("t#{n}", fn ->
            MyApp.Repo.query!("INSERT INTO notes (body) VALUES ('hello')")
          end)
        end,
        max_concurrency: 16,
        timeout: :infinity
      )
      |> Stream.run()
    end)

  open = stats.()
  IO.puts("open:       #{inspect(open)}")

  IO.puts(
    "opening:    #{div(us, 1000)} ms in total, #{Float.round(us / count / 1000, 1)} ms per tenant (16 at a time)"
  )

  IO.puts(
    "per tenant: #{Float.round((open.rss_mb - before.rss_mb) / count, 2)} MB RSS, " <>
      "#{Float.round((open.fds - before.fds) / count, 1)} fds, " <>
      "#{Float.round((open.threads - before.threads) / count, 2)} threads"
  )

  if mode == "s3" do
    Process.sleep(2_000)
    r0 = s3_requests.()
    Process.sleep(idle_s * 1_000)
    r1 = s3_requests.()

    IO.puts(
      "idle:       #{r1 - r0} S3 requests in #{idle_s} s for #{count} tenants = " <>
        "#{Float.round((r1 - r0) / count * 3600 / idle_s, 1)} per tenant per hour"
    )
  end

  {us, _} =
    :timer.tc(fn ->
      1..count
      |> Task.async_stream(&MyApp.Tenants.stop("t#{&1}"), max_concurrency: 16, timeout: :infinity)
      |> Stream.run()
    end)

  :erlang.garbage_collect()
  Process.sleep(1_000)
  IO.puts("stopped:    #{inspect(stats.())} (stopping took #{div(us, 1000)} ms)")
end

File.rm_rf!(dir)
