defmodule S3Demo.Repo do
  use Ecto.Repo, otp_app: :s3_demo, adapter: Ecto.Adapters.Sediment
end
