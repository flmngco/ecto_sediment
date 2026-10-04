defmodule S3Demo.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add(:body, :string, null: false)
      timestamps()
    end
  end
end
