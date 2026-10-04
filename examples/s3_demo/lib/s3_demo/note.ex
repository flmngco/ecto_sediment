defmodule S3Demo.Note do
  use Ecto.Schema

  schema "notes" do
    field(:body, :string)
    timestamps()
  end
end
