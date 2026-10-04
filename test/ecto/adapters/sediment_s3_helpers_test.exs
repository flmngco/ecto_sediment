defmodule Ecto.Adapters.SedimentS3HelpersTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Sediment

  defmodule NamedRepo do
    use Ecto.Repo, otp_app: :ecto_sediment, adapter: Ecto.Adapters.Sediment
  end

  # A plain (non-S3) database answers with an error, which is enough to show
  # the helpers reach a connection instead of looping.
  defp within_a_second(fun), do: fun |> Task.async() |> Task.await(1_000)

  test "a named repo module, its pid and a named dynamic repo all resolve" do
    pid = start_supervised!({NamedRepo, database: Temp.path!(), log: false})

    assert {:error, "not an s3 database"} =
             within_a_second(fn -> Sediment.s3_info(NamedRepo) end)

    assert {:error, "not an s3 database"} =
             within_a_second(fn -> Sediment.s3_info(pid) end)

    assert {:error, "not an s3 replica"} =
             within_a_second(fn -> Sediment.s3_refresh(NamedRepo) end)

    start_supervised!(
      {NamedRepo, name: :named_dynamic_repo, database: Temp.path!(), log: false},
      id: :named_dynamic_repo
    )

    assert {:error, "not an s3 database"} =
             within_a_second(fn -> Sediment.s3_info(:named_dynamic_repo) end)
  end
end
