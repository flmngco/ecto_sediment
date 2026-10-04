defmodule Ecto.Integration.EdgeValuesTest do
  # Boundary values of every Ecto type survive a write and a read back
  use Ecto.Integration.Case

  alias Ecto.Integration.TestRepo

  defmodule Row do
    use Ecto.Schema

    schema "edge_values" do
      field(:int, :integer)
      field(:float, :float)
      field(:string, :string)
      field(:binary, :binary)
      field(:decimal, :decimal)
      field(:decimal_text, :decimal)
      field(:map, :map)
      field(:list, {:array, :string})
      field(:bool, :boolean)
      field(:date, :date)
      field(:time, :time_usec)
      field(:naive, :naive_datetime_usec)
      field(:utc, :utc_datetime_usec)
    end
  end

  setup do
    TestRepo.query!("""
    CREATE TABLE edge_values (
      id INTEGER PRIMARY KEY, int INTEGER, float REAL, string TEXT, binary BLOB,
      decimal DECIMAL, decimal_text TEXT, map TEXT, list TEXT, bool INTEGER, date TEXT, time TEXT,
      naive TEXT, utc TEXT)
    """)

    :ok
  end

  defp round_trip(field, value) do
    %{id: id} = TestRepo.insert!(struct(Row, [{field, value}]))
    TestRepo.get!(Row, id) |> Map.fetch!(field)
  end

  test "64-bit integer bounds" do
    for value <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807, 0, -1] do
      assert round_trip(:int, value) == value
    end
  end

  test "an integer outside 64 bits is an error, not a wrapped value" do
    for value <- [9_223_372_036_854_775_808, -9_223_372_036_854_775_809] do
      assert_raise Sediment.Error, ~r/out of range/, fn ->
        round_trip(:int, value)
      end
    end
  end

  test "float extremes" do
    for value <- [
          1.7_976_931_348_623_157e308,
          -1.7_976_931_348_623_157e308,
          5.0e-324,
          -0.0,
          0.1
        ] do
      assert round_trip(:float, value) === value
    end
  end

  test "strings: empty, NUL bytes, non-BMP characters, 4 MB" do
    big = String.duplicate("é🦀", 700_000)

    for value <- ["", "a\0b\0", "🦀 Ωμέγα 中文 \u{10FFFF}", "'); DROP TABLE x; --", big] do
      assert round_trip(:string, value) == value
    end
  end

  test "binaries: empty, all zero, 8 MB random" do
    for value <- [<<>>, <<0, 0, 0>>, :crypto.strong_rand_bytes(8 * 1024 * 1024)] do
      assert round_trip(:binary, value) == value
    end
  end

  test "an empty string and an empty binary are not NULL" do
    %{id: id} = TestRepo.insert!(%Row{string: "", binary: <<>>})

    assert %{rows: [[0, 0]]} =
             TestRepo.query!(
               "SELECT string IS NULL, binary IS NULL FROM edge_values WHERE id = ?",
               [id]
             )
  end

  # A DECIMAL column has NUMERIC affinity: SQLite stores the value as a REAL
  # when it looks like one, so only about 15 significant digits survive (as
  # with ecto_sqlite3). A TEXT column keeps every digit.
  test "decimals: exact in a TEXT column, up to 15 digits in a DECIMAL column" do
    for value <- ["0", "-0.001", "12345678901234567890.123456789", "1E-30", "0.1"] do
      decimal = Decimal.new(value)
      assert Decimal.equal?(round_trip(:decimal_text, decimal), decimal), value
    end

    for value <- ["0", "-0.001", "1234567.89", "123456789012345"] do
      decimal = Decimal.new(value)
      assert Decimal.equal?(round_trip(:decimal, decimal), decimal), value
    end

    lossy = Decimal.new("12345678901234567890.123456789")
    refute Decimal.equal?(round_trip(:decimal, lossy), lossy)
  end

  test "maps and lists: empty, nested, unicode keys" do
    map = %{"ключ" => [1, 2.5, nil, true], "nested" => %{"deep" => %{"x" => "\0"}}}

    assert round_trip(:map, %{}) == %{}
    assert round_trip(:map, map) == map
    assert round_trip(:list, []) == []
    assert round_trip(:list, ["", "🦀", "\"quoted\""]) == ["", "🦀", "\"quoted\""]
  end

  test "date and time bounds" do
    assert round_trip(:date, ~D[0001-01-01]) == ~D[0001-01-01]
    assert round_trip(:date, ~D[9999-12-31]) == ~D[9999-12-31]
    assert round_trip(:time, ~T[23:59:59.999999]) == ~T[23:59:59.999999]
    assert round_trip(:time, ~T[00:00:00.000000]) == ~T[00:00:00.000000]

    assert round_trip(:naive, ~N[0001-01-01 00:00:00.000000]) ==
             ~N[0001-01-01 00:00:00.000000]

    assert round_trip(:naive, ~N[9999-12-31 23:59:59.999999]) ==
             ~N[9999-12-31 23:59:59.999999]

    utc = ~U[9999-12-31 23:59:59.999999Z]
    assert round_trip(:utc, utc) == utc
  end

  test "a time stored without microseconds loads into a :time_usec field" do
    TestRepo.query!("INSERT INTO edge_values (id, time) VALUES (1, '12:30:00')")
    assert TestRepo.get!(Row, 1).time == ~T[12:30:00.000000]
  end

  # Turso binds up to 250,000 parameters per statement (SQLite: 32,766)
  test "insert_all binds far more parameters than SQLite; beyond the limit, nothing is inserted" do
    rows = fn n -> for i <- 1..n, do: %{int: i, string: "x", float: 1.5} end

    assert {20_000, _} = TestRepo.insert_all(Row, rows.(20_000))

    assert_raise Sediment.Error,
                 ~r/variable number must be between \?1 and \?250000/,
                 fn ->
                   TestRepo.insert_all(Row, rows.(90_000))
                 end

    assert TestRepo.aggregate(Row, :count) == 20_000
  end

  test "booleans" do
    assert round_trip(:bool, true) == true
    assert round_trip(:bool, false) == false
  end

  test "extreme values compare and sort in SQL" do
    for v <- [9_223_372_036_854_775_807, -9_223_372_036_854_775_808, 0],
        do: TestRepo.insert!(%Row{int: v})

    import Ecto.Query

    assert TestRepo.all(from(r in Row, order_by: r.int, select: r.int)) ==
             [-9_223_372_036_854_775_808, 0, 9_223_372_036_854_775_807]

    assert TestRepo.one(from(r in Row, select: max(r.int))) == 9_223_372_036_854_775_807
  end
end
