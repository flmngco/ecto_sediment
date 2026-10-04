import Config

# Read at startup (also inside a release), so the environment variables can
# change without recompiling. The local file is only a working copy; S3 is the
# durable store.
config :s3_demo, S3Demo.Repo,
  database: System.get_env("DATABASE_PATH", Path.expand("../data/demo.db", __DIR__)),
  pool_size: 2,
  # S3 databases are encrypted (the data in the bucket too); without the key
  # nothing can be read back. `encryption: false` would store it unencrypted.
  encryption: [
    cipher: "aegis256",
    key:
      System.get_env("DATABASE_ENCRYPTION_KEY") ||
        raise(
          "set DATABASE_ENCRYPTION_KEY first, e.g. " <>
            "export DATABASE_ENCRYPTION_KEY=$(openssl rand -hex 32)"
        )
  ],
  s3: [
    bucket: System.get_env("S3_BUCKET", "s3-demo"),
    prefix: System.get_env("S3_PREFIX", "demo"),
    endpoint: System.get_env("S3_ENDPOINT", "http://127.0.0.1:8333"),
    region: System.get_env("S3_REGION", "us-east-1"),
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID", "any"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", "any"),
    # A stable owner lets a restarted (or crashed) node take its lease back
    # immediately instead of waiting for it to expire.
    owner: "s3-demo"
  ]
