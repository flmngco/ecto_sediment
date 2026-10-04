defmodule S3Demo.Release do
  @moduledoc """
  Release tasks, as described in ecto_sediment's S3 guide:

      bin/s3_demo eval "S3Demo.Release.migrate()"
      bin/s3_demo eval "S3Demo.Release.show()"
  """
  @app :s3_demo

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def show do
    Application.load(@app)
    S3Demo.with_repo(&S3Demo.show/0)
  end
end
