defmodule Mix.Tasks.EctoSediment.Install.Docs do
  @moduledoc false

  def short_doc, do: "Sets up an Ecto repo using ecto_sediment"

  def example, do: "mix igniter.install ecto_sediment"

  def long_doc do
    """
    #{short_doc()}.

    Creates `MyApp.Repo` (unless it exists), adds it to the supervision tree
    and to `:ecto_repos`, and configures it the way Phoenix configures
    ecto_sqlite3 repos: a local database file in dev and test (with the SQL
    sandbox in test) and `DATABASE_PATH` in `config/runtime.exs` for prod.

    ## Example

    ```sh
    #{example()}
    mix igniter.install ecto_sediment --s3
    ```

    ## Options

      * `--repo` or `-r` - the repo module, defaults to `MyApp.Repo`
      * `--s3` - configure the prod repo as an S3-backed database, read from
        the `S3_BUCKET`, `S3_PREFIX`, `S3_ENDPOINT`, `AWS_REGION`,
        `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `S3_OWNER` (the
        writer lease owner, defaulting to the hostname; see the S3 guide)
        environment variables in `config/runtime.exs`, encrypted with the key
        in `DATABASE_ENCRYPTION_KEY` (64 hex characters, e.g. from
        `openssl rand -hex 32`), and use integer primary keys in migrations
        (`migration_primary_key: [type: :integer]`), which are much faster in
        the MVCC mode S3 repos use
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.EctoSediment.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ecto_sediment,
        example: __MODULE__.Docs.example(),
        schema: [repo: :string, s3: :boolean],
        defaults: [s3: false],
        aliases: [r: :repo]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      opts = igniter.args.options

      repo =
        case opts[:repo] do
          nil -> Igniter.Project.Module.module_name(igniter, "Repo")
          name -> Igniter.Project.Module.parse(name)
        end

      igniter
      |> create_repo(repo, app_name)
      |> Igniter.Project.Config.configure("config.exs", app_name, [:ecto_repos], [repo],
        updater: &Igniter.Code.List.prepend_new_to_list(&1, repo)
      )
      |> configure_env("dev.exs", app_name, repo, dev_config(app_name))
      |> configure_env("test.exs", app_name, repo, test_config(app_name))
      |> configure_runtime(app_name, repo, opts[:s3])
      |> maybe_integer_primary_keys(app_name, repo, opts[:s3])
      |> Igniter.Project.Application.add_new_child(repo)
      |> Igniter.Project.Formatter.import_dep(:ecto)
      |> Igniter.Project.Formatter.import_dep(:ecto_sql)
      |> Igniter.add_notice("""
      ecto_sediment: #{inspect(repo)} is ready. Create the database with `mix ecto.create`.
      """)
      |> maybe_encryption_notice(opts[:s3])
    end

    defp maybe_encryption_notice(igniter, true) do
      Igniter.add_notice(igniter, """
      ecto_sediment: S3 databases are encrypted. In prod, set DATABASE_ENCRYPTION_KEY to
      a key generated with `openssl rand -hex 32` and keep it safe: without it the data
      in S3 can't be read. To store the database unencrypted instead, replace the
      `encryption:` line in config/runtime.exs with `encryption: false`.
      """)
    end

    defp maybe_encryption_notice(igniter, _s3?), do: igniter

    defp create_repo(igniter, repo, app_name) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, repo)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, repo, """
        use Ecto.Repo,
          otp_app: #{inspect(app_name)},
          adapter: Ecto.Adapters.Sediment
        """)
      end
    end

    # S3 repos run in MVCC mode, where turso_core handles AUTOINCREMENT (Ecto's
    # default :bigserial primary keys) slowly; set for every environment so
    # the schema is the same everywhere.
    defp maybe_integer_primary_keys(igniter, app_name, repo, true) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        app_name,
        [repo, :migration_primary_key],
        type: :integer
      )
    end

    defp maybe_integer_primary_keys(igniter, _app_name, _repo, _s3?), do: igniter

    defp dev_config(app_name) do
      quote do
        [
          database: Path.expand(unquote("../#{app_name}_dev.db"), __DIR__),
          pool_size: 5,
          stacktrace: true,
          show_sensitive_data_on_connection_error: true
        ]
      end
    end

    defp test_config(app_name) do
      quote do
        [
          database: Path.expand(unquote("../#{app_name}_test.db"), __DIR__),
          pool_size: 5,
          pool: Ecto.Adapters.SQL.Sandbox
        ]
      end
    end

    defp configure_env(igniter, file, app_name, repo, config) do
      Igniter.Project.Config.configure_new(
        igniter,
        file,
        app_name,
        [repo],
        {:code, config}
      )
    end

    defp configure_runtime(igniter, app_name, repo, s3?) do
      Igniter.Project.Config.configure_runtime_env(
        igniter,
        :prod,
        app_name,
        [repo],
        {:code, runtime_config(s3?)}
      )
    end

    defp runtime_config(false) do
      quote do
        [
          database:
            System.get_env("DATABASE_PATH") ||
              raise("environment variable DATABASE_PATH is missing"),
          pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
        ]
      end
    end

    defp runtime_config(true) do
      quote do
        [
          # Only a working copy: the database lives in S3
          database: System.get_env("DATABASE_PATH") || "/tmp/app.db",
          pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
          encryption: [
            cipher: "aegis256",
            key:
              System.get_env("DATABASE_ENCRYPTION_KEY") ||
                raise(
                  "environment variable DATABASE_ENCRYPTION_KEY is missing: S3 databases " <>
                    "are encrypted. Generate a key with `openssl rand -hex 32`, or set " <>
                    "`encryption: false` in config/runtime.exs to store the database unencrypted."
                )
          ],
          s3: [
            bucket:
              System.get_env("S3_BUCKET") ||
                raise("environment variable S3_BUCKET is missing"),
            prefix: System.get_env("S3_PREFIX") || "db",
            endpoint: System.get_env("S3_ENDPOINT"),
            region: System.get_env("AWS_REGION") || "us-east-1",
            access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
            secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
            # A stable owner per machine lets a restarted node take its lease back at
            # once; nodes running at the same time must not share one
            owner:
              System.get_env("S3_OWNER") ||
                :inet.gethostname() |> elem(1) |> List.to_string()
          ]
        ]
      end
    end
  end
else
  defmodule Mix.Tasks.EctoSediment.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ecto_sediment.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
