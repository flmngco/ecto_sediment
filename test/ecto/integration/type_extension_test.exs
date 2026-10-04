defmodule Ecto.Integration.TypeExtensionTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias EctoSediment.DynamicRepo, as: Repo

  # An Ecto type whose primitive type (:point) only the extension knows how to
  # store: as "x,y" text.
  defmodule Point do
    use Ecto.Type
    def type, do: :point
    def cast({x, y}) when is_number(x) and is_number(y), do: {:ok, {x, y}}
    def cast(_), do: :error
    def dump({_, _} = point), do: {:ok, point}
    def load({_, _} = point), do: {:ok, point}
  end

  defmodule PointExtension do
    @behaviour Ecto.Adapters.Sediment.TypeExtension

    @impl true
    def loaders(:point, type), do: [&decode/1, type]
    def loaders(_, _), do: nil

    @impl true
    def dumpers(:point, type), do: [type, &encode/1]
    def dumpers(_, _), do: nil

    defp encode({x, y}), do: {:ok, "#{x},#{y}"}

    # Loaders also receive NULL values
    defp decode(nil), do: {:ok, nil}

    defp decode(text) do
      [x, y] = text |> String.split(",") |> Enum.map(&String.to_integer/1)
      {:ok, {x, y}}
    end
  end

  # An extension that handles nothing, to check the lookup falls through
  defmodule NoopExtension do
    @behaviour Ecto.Adapters.Sediment.TypeExtension
    @impl true
    def loaders(_, _), do: nil
    @impl true
    def dumpers(_, _), do: nil
  end

  defmodule Place do
    use Ecto.Schema

    schema "places" do
      field(:name, :string)
      field(:location, Point)
    end
  end

  setup do
    Application.put_env(:ecto_sediment, :type_extensions, [
      NoopExtension,
      PointExtension
    ])

    on_exit(fn -> Application.delete_env(:ecto_sediment, :type_extensions) end)
    Repo.start_supervised!(database: Temp.path!())

    Repo.query!(
      "CREATE TABLE places (id INTEGER PRIMARY KEY, name TEXT, location TEXT)"
    )

    :ok
  end

  test "types no extension handles are passed through unchanged" do
    Repo.insert!(%Place{name: "plain"})
    assert ["plain"] == Repo.all(from(p in Place, select: p.name))
  end

  test "extensions dump and load custom primitive types" do
    %Place{id: id} = Repo.insert!(%Place{name: "home", location: {3, 4}})
    assert %{rows: [["3,4"]]} = Repo.query!("SELECT location FROM places")
    assert %Place{location: {3, 4}} = Repo.get!(Place, id)
  end

  test "NULL values reach the extension's loader" do
    %Place{id: id} = Repo.insert!(%Place{name: "unnamed"})
    assert %Place{name: "unnamed", location: nil} = Repo.get!(Place, id)
  end
end
