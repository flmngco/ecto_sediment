defmodule EctoSediment.Schemas.Schema2 do
  @moduledoc false

  use Ecto.Schema

  schema "schema2" do
    belongs_to(:post, EctoSediment.Schemas.Schema,
      references: :x,
      foreign_key: :z
    )
  end
end
