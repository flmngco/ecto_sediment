defmodule S3Demo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The demo tasks start the repo themselves.
    Supervisor.start_link([], strategy: :one_for_one, name: S3Demo.Supervisor)
  end
end
