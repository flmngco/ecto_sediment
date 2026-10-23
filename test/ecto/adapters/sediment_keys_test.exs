defmodule Ecto.Adapters.SedimentKeysTest do
  # Options and repo configurations of the wrong shape, holding keys, at
  # every function of the adapter (and Mix task) taking them: no key in a
  # result, an exception's message or inspect, or its stack trace.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Sediment, as: Adapter
  alias EctoSediment.DynamicRepo
  alias Mix.Tasks.Ecto.Sediment.ExportSqlite
  alias Mix.Tasks.Ecto.Sediment.S3.Import
  alias Mix.Tasks.Ecto.Sediment.S3.Restore

  @k1 String.duplicate("1a", 32)
  @k2 String.duplicate("2b", 32)

  defp ring, do: [keys: [{"r2", @k2}, {"r1", @k1}], cipher: "aegis256"]
  defp s3, do: [bucket: "b", prefix: "p", endpoint: "http://127.0.0.1:1"]

  # Options of the wrong shape around a correct ring.
  defp misshapen_opts do
    [
      {"map", %{encryption: ring()}},
      {"tuple", {:encryption, ring()}},
      {"a key", @k1},
      {"a bare ring", ring()},
      {"key: beside encryption:", [encryption: ring(), key: @k1]}
    ]
  end

  # S3 options (or what is given in their place) holding a key.
  defp misshapen_s3 do
    [
      {"s3 encryption: key", s3() ++ [encryption: @k1]},
      {"s3 durability: key", s3() ++ [durability: @k1]},
      {"s3 {key, id}", s3() ++ [{@k1, "r1"}]},
      {"s3 map", Map.new(s3() ++ [encryption: @k1])},
      {"s3 tuple", {:bucket, @k1}},
      {"a key", @k1}
    ]
  end

  # What a call shows: its result, or its exception (message, inspect,
  # stack trace).
  defp shown(fun) do
    case fun.() do
      {:ok, _} = ok -> {:ok, [inspect(ok)]}
      result -> {:error, [inspect(result, limit: :infinity)]}
    end
  rescue
    exception ->
      {:raised,
       [
         Exception.format(:error, exception, __STACKTRACE__),
         inspect(exception, limit: :infinity),
         inspect(__STACKTRACE__, limit: :infinity)
       ]}
  end

  defp refute_keys(texts, case) do
    for text <- texts, key <- [@k1, @k2], i <- 0..(byte_size(key) - 16) do
      refute text =~ binary_part(key, i, 16), "#{case}: #{text}"
    end
  end

  defp refute_shown(fun, case) do
    {outcome, texts} = shown(fun)
    assert outcome != :ok, "#{case}: accepted"
    refute_keys(texts, case)
  end

  test "the adapter's functions never show a key given in the wrong shape" do
    source = Temp.path!()

    for {case, opts} <- misshapen_opts(),
        {call, fun} <- [
          s3_restore: &Adapter.s3_restore(s3(), Temp.path!(), &1),
          s3_import: &Adapter.s3_import(s3(), source, &1),
          s3_destroy: &Adapter.s3_destroy(s3(), &1),
          export_sqlite: &Adapter.export_sqlite(s3(), Temp.path!(), &1)
        ] do
      refute_shown(fn -> fun.(opts) end, "#{call}, #{case}")
    end

    for {case, s3} <- misshapen_s3(),
        {call, fun} <- [
          s3_restore: &Adapter.s3_restore(&1, Temp.path!(), encryption: ring()),
          s3_import: &Adapter.s3_import(&1, source, encryption: ring()),
          s3_exists?: &Adapter.s3_exists?/1,
          s3_destroy: &Adapter.s3_destroy/1,
          export_sqlite: &Adapter.export_sqlite(&1, Temp.path!(), encryption: ring())
        ] do
      refute_shown(fn -> fun.(s3) end, "#{call}, #{case}")
    end
  end

  test "the storage callbacks never show a key in a configuration of the wrong shape" do
    for {case, config} <- [
          {"map", %{database: Temp.path!(), encryption: ring()}},
          {"no :database", [databse: Temp.path!(), encryption: ring()]},
          {"a bare ring", ring()},
          {"s3 encryption: key",
           [database: Temp.path!(), s3: s3() ++ [encryption: @k1]]}
        ],
        {call, fun} <- [
          storage_up: &Adapter.storage_up/1,
          storage_down: &Adapter.storage_down/1,
          storage_status: &Adapter.storage_status/1
        ],
        # storage_status/1 and storage_down/1 don't open the database.
        not (case == "s3 encryption: key" and call != :storage_up) do
      refute_shown(fn -> fun.(config) end, "#{call}, #{case}")
    end
  end

  # Wrong shapes, each holding `key`.
  defp shapes(key) do
    ring = [keys: [{"r1", key}], cipher: "aegis256"]

    [
      key,
      String.to_atom(key),
      %{encryption: ring},
      ring,
      [encryption: ring],
      [encryption: [keys: [{"r1", [key: key]}]]],
      [{key, "r1"}],
      {:global, ring},
      %{bucket: "b", encryption: key},
      [bucket: "b", encryption: key],
      [s3: [ring]]
    ]
  end

  # The callbacks taking the repo's configuration, besides the documented
  # functions.
  @callbacks [
    storage_up: 1,
    storage_down: 1,
    storage_status: 1,
    structure_dump: 2,
    structure_load: 2
  ]

  test "no documented function or configuration callback shows a key, in any shape" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Adapter)

    documented =
      for {{:function, name, arity}, _, _, doc, _} <- docs,
          doc != :hidden,
          do: {name, arity}

    assert {:dump_cmd, 3} in documented
    assert {:s3_refresh, 1} in documented

    for {name, arity} <- documented ++ @callbacks,
        key <- [@k1, String.duplicate("6e", 16)],
        position <- 0..(arity - 1),
        shape <- shapes(key),
        fill <- [nil, shape] do
      args = fill |> List.duplicate(arity) |> List.replace_at(position, shape)
      {_outcome, texts} = shown(fn -> apply(Adapter, name, args) end)

      for text <- texts, i <- 0..(byte_size(key) - 16) do
        refute text =~ binary_part(key, i, 16),
               "#{name}/#{arity}, argument #{position + 1}"
      end
    end
  end

  describe "the Mix tasks" do
    setup do
      on_exit(fn -> Application.delete_env(:ecto_sediment, DynamicRepo) end)
    end

    test "never show a key from a repo configuration of the wrong shape" do
      repo = ["-r", inspect(DynamicRepo), "--no-compile"]
      source = Temp.path!()

      for {case, s3} <- misshapen_s3(),
          {task, args} <- [
            {Restore, ["-o", Temp.path!()]},
            {Import, ["--source", source]},
            {ExportSqlite, ["-o", Temp.path!()]}
          ] do
        Application.put_env(:ecto_sediment, DynamicRepo,
          database: Temp.path!(),
          s3: s3,
          encryption: ring(),
          log: false
        )

        refute_shown(fn -> task.run(repo ++ args) end, "#{inspect(task)}, #{case}")
      end
    end
  end
end
