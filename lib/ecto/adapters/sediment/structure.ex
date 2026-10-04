defmodule Ecto.Adapters.Sediment.Structure do
  @moduledoc false

  # In-process replacement for the handful of `sqlite3` CLI features that
  # ecto_sqlite3 shells out to (`.schema`, `.mode insert`, `.read`). Turso has
  # no widely installed CLI, so we go through the driver instead.

  alias Sediment.Engine

  @schema_query """
  SELECT sql FROM sqlite_schema
  WHERE sql IS NOT NULL
    AND name NOT LIKE 'sqlite_%'
    AND name NOT LIKE '__turso_internal_%'
  """

  def dump_schema(config) do
    with_db(config, fn db ->
      with {:ok, rows} <- query(db, @schema_query) do
        {:ok, Enum.map_join(rows, fn [sql] -> sql <> ";\n" end)}
      end
    end)
  end

  def dump_versions(config, table) do
    with_db(config, fn db ->
      with {:ok, rows} <- query(db, "SELECT * FROM #{quote_name(table)}") do
        {:ok, rows |> Enum.map(&insert_statement(table, &1)) |> IO.iodata_to_binary()}
      end
    end)
  end

  def load(config, path) do
    case File.read(path) do
      {:ok, sql} ->
        with_db(config, fn db -> Engine.execute(db, sql) end)

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Emulates `sqlite3 DATABASE ARGS...`: every arg is either SQL or `.schema`.
  # Returns `{output, exit_status}` like `System.cmd/3`.
  def run(args, config) do
    result =
      with_db(config, fn db ->
        Enum.reduce_while(args, {:ok, []}, &run_arg(db, &1, &2))
      end)

    case result do
      {:ok, out} -> {IO.iodata_to_binary(out), 0}
      {:error, reason} -> {error_message(reason), 1}
    end
  end

  defp run_arg(db, arg, {:ok, acc}) do
    case run_arg(db, arg) do
      {:ok, out} -> {:cont, {:ok, [acc | out]}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp run_arg(db, ".schema") do
    with {:ok, rows} <- query(db, @schema_query) do
      {:ok, Enum.map(rows, fn [sql] -> [sql, ";\n"] end)}
    end
  end

  defp run_arg(_db, "." <> _ = command), do: {:error, "unsupported command: #{command}"}

  defp run_arg(db, sql) do
    with {:ok, rows} <- query(db, sql) do
      {:ok, Enum.map(rows, fn row -> [Enum.map_join(row, "|", &to_text/1), "\n"] end)}
    end
  end

  defp with_db(config, fun) do
    case config
         |> Ecto.Adapters.Sediment.Connection.normalize_opts()
         |> Sediment.Connection.connect() do
      {:ok, state} ->
        try do
          state.db |> fun.() |> with_message()
        after
          Sediment.Connection.disconnect(:normal, state)
        end

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  # Like the sqlite3 CLI in ecto_sqlite3, errors are reported as strings
  defp with_message({:error, reason}), do: {:error, error_message(reason)}
  defp with_message(other), do: other

  defp query(db, sql) do
    with {:ok, stmt} <- Engine.prepare(db, sql) do
      try do
        Engine.fetch_all(db, stmt)
      after
        Engine.release(db, stmt)
      end
    end
  end

  defp insert_statement(table, row) do
    values = row |> Enum.map(&literal/1) |> Enum.intersperse(",")
    ["INSERT INTO ", quote_name(table), " VALUES(", values, ");\n"]
  end

  defp literal(nil), do: "NULL"
  defp literal(value) when is_integer(value) or is_float(value), do: to_string(value)

  defp literal(value) when is_binary(value) do
    if String.printable?(value) do
      ["'", String.replace(value, "'", "''"), "'"]
    else
      ["X'", Base.encode16(value), "'"]
    end
  end

  defp to_text(nil), do: ""
  defp to_text(value), do: to_string(value)

  defp quote_name(name), do: [?", String.replace(to_string(name), "\"", "\"\""), ?"]

  defp error_message(%{message: message}), do: message
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
