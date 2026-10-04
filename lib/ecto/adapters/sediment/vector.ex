defmodule Ecto.Adapters.Sediment.Vector do
  @moduledoc """
  An `Ecto.Type` for Turso's native dense 32-bit float vectors.

  Values are lists of numbers in Elixir and stored as Turso `vector32` blobs
  (little-endian `f32`s), so they work directly with Turso's vector functions
  such as `vector_distance_cos/2`. Use `Ecto.Adapters.Sediment.Vector64` for
  64-bit vectors.

  ## Schema and migration

      schema "documents" do
        field :embedding, Ecto.Adapters.Sediment.Vector
      end

      create table(:documents) do
        add :embedding, :vector32, size: 3
      end

  The `:vector32` (alias `:vector`) and `:vector64` migration types generate
  `F32_BLOB(size)` and `F64_BLOB(size)` columns, the same names libSQL uses.

  ## Queries

  See `Ecto.Adapters.Sediment.Vector.Query` for distance helpers:

      import Ecto.Adapters.Sediment.Vector.Query

      from d in Document,
        order_by: vector_distance_cos(d.embedding, ^[1.0, 0.0, 0.0]),
        limit: 5
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(list) when is_list(list) do
    if Enum.all?(list, &is_number/1),
      do: {:ok, Enum.map(list, &(&1 * 1.0))},
      else: :error
  end

  def cast(_), do: :error

  @impl true
  def dump(list) when is_list(list) do
    {:blob, blob} = Sediment.Vector.new(list, :f32)
    {:ok, blob}
  end

  def dump(_), do: :error

  @impl true
  def load(blob) when is_binary(blob) and rem(byte_size(blob), 4) == 0,
    do: {:ok, Sediment.Vector.to_list(blob)}

  def load(_), do: :error
end

defmodule Ecto.Adapters.Sediment.Vector64 do
  @moduledoc """
  An `Ecto.Type` for Turso's native dense 64-bit float vectors (`vector64`).

  Works like `Ecto.Adapters.Sediment.Vector`. Use the `:vector64` migration type.
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  defdelegate cast(value), to: Ecto.Adapters.Sediment.Vector

  @impl true
  def dump(list) when is_list(list) do
    {:blob, blob} = Sediment.Vector.new(list, :f64)
    {:ok, blob}
  end

  def dump(_), do: :error

  @impl true
  def load(blob)
      when is_binary(blob) and rem(byte_size(blob), 8) == 1 and
             binary_part(blob, byte_size(blob) - 1, 1) == <<2>>,
      do: {:ok, Sediment.Vector.to_list(blob)}

  def load(_), do: :error
end

defmodule Ecto.Adapters.Sediment.Vector.Query do
  @moduledoc """
  Query macros for Turso's vector functions.

  Turso's distance functions raise an error (`"Invalid vector type"`) for
  `NULL` vectors instead of returning `NULL`, so filter out rows without a
  vector (`where: not is_nil(d.embedding)`) when the column is nullable.

  Pinned lists are converted to `vector32` blobs automatically; to compare
  against 64-bit vectors, pin a value cast with `type(^list, Ecto.Adapters.Sediment.Vector64)`.

      import Ecto.Adapters.Sediment.Vector.Query

      from d in Document,
        select: {d.id, vector_distance_l2(d.embedding, ^query_embedding)},
        order_by: vector_distance_l2(d.embedding, ^query_embedding)
  """

  @doc "Cosine distance (`1 - cosine similarity`) between two vectors."
  defmacro vector_distance_cos(left, right),
    do: distance("vector_distance_cos", left, right)

  @doc "Euclidean (L2) distance between two vectors."
  defmacro vector_distance_l2(left, right),
    do: distance("vector_distance_l2", left, right)

  @doc "Negative dot product between two vectors."
  defmacro vector_distance_dot(left, right),
    do: distance("vector_distance_dot", left, right)

  @doc "Jaccard distance between two vectors, best suited to `vector1bit` vectors."
  defmacro vector_distance_jaccard(left, right),
    do: distance("vector_distance_jaccard", left, right)

  @doc "Converts a vector blob into its JSON text representation."
  defmacro vector_extract(vector) do
    quote do: fragment("vector_extract(?)", unquote(vector_arg(vector)))
  end

  defp distance(function, left, right) do
    sql = function <> "(?, ?)"

    quote do
      fragment(unquote(sql), unquote(vector_arg(left)), unquote(vector_arg(right)))
    end
  end

  defp vector_arg({:^, _, _} = pinned) do
    quote do: type(unquote(pinned), Ecto.Adapters.Sediment.Vector)
  end

  defp vector_arg(other), do: other
end
