Code.require_file("repos.exs", __DIR__)
Code.require_file("migrations.exs", __DIR__)
Code.require_file("schemas.exs", __DIR__)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
# SeaweedFS accepts unsigned requests; with real S3 create the bucket yourself.
{:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", 8333, [:binary, active: false])
bucket = System.get_env("S3_BUCKET", "ecto-tests")

:ok =
  :gen_tcp.send(socket, "PUT /#{bucket} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n")

{:ok, _} = :gen_tcp.recv(socket, 0)
:gen_tcp.close(socket)

for repo <- Ecto.Bench.Repos.all() do
  adapter = repo.__adapter__()
  _ = adapter.storage_down(repo.config())
  :ok = adapter.storage_up(repo.config())
  {:ok, _} = repo.start_link()
  :ok = Ecto.Migrator.up(repo, 0, Ecto.Bench.CreateUser, log: false)
end
