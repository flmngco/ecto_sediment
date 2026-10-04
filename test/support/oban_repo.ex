defmodule EctoSediment.ObanRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :ecto_sediment, adapter: Ecto.Adapters.Sediment
end

defmodule EctoSediment.ObanMigration do
  @moduledoc false
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end

defmodule EctoSediment.ObanWorker do
  @moduledoc false
  # Reports every attempt to the test process registered as args["to"]; fails
  # the first `fail` attempts.
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    send(String.to_existing_atom(args["to"]), {:performed, args["id"], attempt})

    if attempt <= Map.get(args, "fail", 0),
      do: {:error, "failing attempt #{attempt}"},
      else: :ok
  end

  @impl Oban.Worker
  def backoff(_job), do: 0
end
