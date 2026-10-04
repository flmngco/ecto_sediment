defmodule EctoSediment.DynamicRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :ecto_sediment, adapter: Ecto.Adapters.Sediment

  # Starts an unnamed instance under the test supervisor and makes it the
  # dynamic repo of the calling test process.
  def start_supervised!(config) do
    spec =
      Supervisor.child_spec({__MODULE__, [name: nil, log: false] ++ config},
        id: make_ref(),
        restart: :temporary
      )

    pid = ExUnit.Callbacks.start_supervised!(spec)
    put_dynamic_repo(pid)
    pid
  end
end
