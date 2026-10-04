defmodule EctoSediment.Schemas.Schema do
  @moduledoc false

  use Ecto.Schema

  schema "schema" do
    field(:x, :integer)
    field(:y, :integer)
    field(:z, :integer)
    field(:w, {:array, :integer})
    field(:meta, :map)

    has_many(:comments, EctoSediment.Schemas.Schema2,
      references: :x,
      foreign_key: :z
    )

    has_one(:permalink, EctoSediment.Schemas.Schema3,
      references: :y,
      foreign_key: :id
    )
  end
end
