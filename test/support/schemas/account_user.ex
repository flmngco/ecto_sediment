defmodule EctoSediment.Schemas.AccountUser do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias EctoSediment.Schemas.Account
  alias EctoSediment.Schemas.User

  schema "account_users" do
    timestamps()

    belongs_to(:account, Account)
    belongs_to(:user, User)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:account_id, :user_id])
    |> validate_required([:account_id, :user_id])
  end
end
