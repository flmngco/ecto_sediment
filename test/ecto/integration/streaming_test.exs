defmodule Ecto.Integration.StreamingTest do
  use Ecto.Integration.Case

  alias Ecto.Integration.TestRepo
  alias EctoSediment.Schemas.User

  import Ecto.Query

  test "handles streams properly" do
    before_count = User |> select([u], u) |> TestRepo.all() |> Enum.count()

    {:ok, _} = TestRepo.insert(User.changeset(%User{}, %{name: "Bill"}))
    {:ok, _} = TestRepo.insert(User.changeset(%User{}, %{name: "Shannon"}))
    {:ok, _} = TestRepo.insert(User.changeset(%User{}, %{name: "Tom"}))
    {:ok, _} = TestRepo.insert(User.changeset(%User{}, %{name: "Tiffany"}))
    {:ok, _} = TestRepo.insert(User.changeset(%User{}, %{name: "Dave"}))

    {:ok, count} =
      TestRepo.transaction(fn ->
        User
        |> select([u], u)
        |> TestRepo.stream()
        |> Enum.count()
      end)

    assert 5 == count - before_count
  end
end
