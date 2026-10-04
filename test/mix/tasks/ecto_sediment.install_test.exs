defmodule Mix.Tasks.EctoSediment.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp install(argv \\ []) do
    test_project(app_name: :my_app)
    |> Igniter.compose_task("ecto_sediment.install", argv)
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  test "creates the repo module" do
    install()
    |> assert_creates("lib/my_app/repo.ex", """
    defmodule MyApp.Repo do
      use Ecto.Repo,
        otp_app: :my_app,
        adapter: Ecto.Adapters.Sediment
    end
    """)
  end

  test "configures dev, test and prod like Phoenix does for ecto_sqlite3" do
    igniter = install()

    config = content(igniter, "config/config.exs")
    assert config =~ "ecto_repos: [MyApp.Repo]"

    dev = content(igniter, "config/dev.exs")
    assert dev =~ ~s{database: Path.expand("../my_app_dev.db", __DIR__)}
    assert dev =~ "show_sensitive_data_on_connection_error: true"

    test = content(igniter, "config/test.exs")
    assert test =~ ~s{database: Path.expand("../my_app_test.db", __DIR__)}
    assert test =~ "pool: Ecto.Adapters.SQL.Sandbox"

    runtime = content(igniter, "config/runtime.exs")
    assert runtime =~ "if config_env() == :prod do"
    assert runtime =~ ~s{System.get_env("DATABASE_PATH")}
    refute runtime =~ "s3:"
  end

  test "adds the repo to the supervision tree and the formatter" do
    igniter = install()
    assert content(igniter, "lib/my_app/application.ex") =~ "MyApp.Repo"
    assert content(igniter, ".formatter.exs") =~ ":ecto_sql"
  end

  test "--s3 configures an S3-backed prod repo from environment variables" do
    runtime = install(["--s3"]) |> content("config/runtime.exs")
    assert runtime =~ "s3: ["
    assert runtime =~ ~s{System.get_env("S3_BUCKET")}
    assert runtime =~ ~s{System.get_env("AWS_SECRET_ACCESS_KEY")}
    assert runtime =~ ":inet.gethostname()"
    assert runtime =~ ~s{System.get_env("DATABASE_ENCRYPTION_KEY")}
    assert runtime =~ ~s{cipher: "aegis256"}
  end

  test "--s3 uses integer primary keys in migrations, only then" do
    assert install(["--s3"]) |> content("config/config.exs") =~
             "migration_primary_key: [type: :integer]"

    refute install() |> content("config/config.exs") =~ "migration_primary_key"
  end

  test "--repo names the repo and an existing repo module is kept" do
    igniter =
      test_project(
        app_name: :my_app,
        files: %{
          "lib/my_app/data.ex" =>
            "defmodule MyApp.Data do\n  def custom, do: :ok\nend\n"
        }
      )
      |> Igniter.compose_task("ecto_sediment.install", ["--repo", "MyApp.Data"])

    assert content(igniter, "lib/my_app/data.ex") =~ "def custom"
    assert content(igniter, "config/config.exs") =~ "ecto_repos: [MyApp.Data]"
  end

  test "running it twice changes nothing more" do
    install()
    |> apply_igniter!()
    |> Igniter.compose_task("ecto_sediment.install", [])
    |> assert_unchanged()
  end
end
