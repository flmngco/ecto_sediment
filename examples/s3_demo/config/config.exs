import Config

config :s3_demo, ecto_repos: [S3Demo.Repo]

# S3 repos run in MVCC mode, where plain integer primary keys are much faster
# than Ecto's default AUTOINCREMENT ones
config :s3_demo, S3Demo.Repo, migration_primary_key: [type: :integer]

config :logger, level: :warning
