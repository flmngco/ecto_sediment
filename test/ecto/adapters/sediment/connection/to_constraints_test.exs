defmodule Ecto.Adapters.Sediment.Connection.ToConstraintsTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.Sediment.Connection

  test "unique index" do
    # created with:
    # CREATE UNIQUE INDEX users_email_name_index ON users (email);

    error = %Sediment.Error{message: "UNIQUE constraint failed: users.email"}
    assert Connection.to_constraints(error, []) == [unique: "users_email_index"]
  end

  test "multi-column unique index" do
    # created with:
    # CREATE UNIQUE INDEX users_email_name_index ON users (email, name);

    error = %Sediment.Error{
      message: "UNIQUE constraint failed: users.email, users.name"
    }

    assert Connection.to_constraints(error, []) == [unique: "users_email_name_index"]
  end

  test "multi-column unique index in turso format" do
    error = %Sediment.Error{message: "UNIQUE constraint failed: users.(email, name)"}
    assert Connection.to_constraints(error, []) == [unique: "users_email_name_index"]
  end

  test "check constraint" do
    error = %Sediment.Error{message: "CHECK constraint failed: positive_price"}
    assert Connection.to_constraints(error, []) == [check: "positive_price"]
  end

  test "foreign key constraint" do
    error = %Sediment.Error{message: "FOREIGN KEY constraint failed"}
    assert Connection.to_constraints(error, []) == [foreign_key: nil]
  end

  test "complex unique index" do
    # created with:
    # CREATE UNIQUE INDEX users_email_year_index ON users (email, strftime('%Y', inserted_at));

    error = %Sediment.Error{
      message: "UNIQUE constraint failed: index 'users_email_year_index'"
    }

    assert Connection.to_constraints(error, []) == [unique: "users_email_year_index"]
  end
end
