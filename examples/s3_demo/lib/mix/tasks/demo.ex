defmodule Mix.Tasks.Demo.Bucket do
  @shortdoc "Creates the S3 bucket (SeaweedFS accepts unsigned requests)"
  @moduledoc @shortdoc
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:ssl, :inets])
    s3 = Application.fetch_env!(:s3_demo, S3Demo.Repo)[:s3]
    url = ~c"#{s3[:endpoint]}/#{s3[:bucket]}"

    # An unsigned request works on SeaweedFS. Servers that require signed
    # requests (MinIO, AWS S3, ...) refuse it: then the bucket must already exist.
    case :httpc.request(:put, {url, [], ~c"application/octet-stream", ""}, [], []) do
      {:ok, {{_, status, _}, _, _}} when status in [200, 409] ->
        Mix.shell().info("bucket #{s3[:bucket]} ready at #{s3[:endpoint]}")

      {:ok, {{_, status, _}, _, _}} when status in [401, 403] ->
        Mix.shell().info(
          "#{s3[:endpoint]} needs signed requests; make sure bucket #{s3[:bucket]} exists"
        )

      other ->
        Mix.raise("could not reach #{s3[:endpoint]}: #{inspect(other)}")
    end
  end
end

defmodule Mix.Tasks.Demo.Write do
  @shortdoc "Writes N notes one commit at a time: mix demo.write 1000"
  @moduledoc @shortdoc
  use Mix.Task

  @impl true
  def run(args) do
    count = args |> List.first("100") |> String.to_integer()
    Mix.Task.run("app.start")
    S3Demo.with_repo(fn -> S3Demo.write(count) end)
  end
end

defmodule Mix.Tasks.Demo.Show do
  @shortdoc "Prints the number of notes and the latest ones"
  @moduledoc @shortdoc
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    S3Demo.with_repo(&S3Demo.show/0)
  end
end

defmodule Mix.Tasks.Demo.Wipe do
  @shortdoc "Deletes the local working copy (simulates losing the machine)"
  @moduledoc @shortdoc
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    dir = Path.dirname(Application.fetch_env!(:s3_demo, S3Demo.Repo)[:database])
    File.rm_rf!(dir)
    Mix.shell().info("deleted #{dir}")
  end
end
