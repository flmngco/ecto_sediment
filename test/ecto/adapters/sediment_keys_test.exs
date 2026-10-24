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

  # Configurations right but for one value, holding `key` (or missing what
  # Ecto requires).
  defp configs(key) do
    ring = [keys: [{"r1", key}], cipher: "aegis256"]
    base = [database: ":memory:", telemetry_prefix: [:review]]

    [
      base ++ [encryption: ring, pool: ring],
      base ++ [encryption: ring, pool: String.to_atom(key)],
      base ++ [encryption: ring, pool_size: key],
      [database: ":memory:", encryption: ring],
      Map.new(base ++ [encryption: ring])
    ]
  end

  # The callbacks taking the repo's configuration, besides the documented
  # functions: the configuration callbacks (a repo's start runs its
  # configuration through them), storage and structure.
  @callbacks [
    init: 1,
    ensure_all_started: 2,
    storage_up: 1,
    storage_down: 1,
    storage_status: 1,
    structure_dump: 2,
    structure_load: 2
  ]

  # What the arguments not probed can be: nil, the shape probed, a valid
  # configuration or a start type.
  @valid [[database: ":memory:", telemetry_prefix: [:review]], :temporary]

  defp fills(arity, position, shape) do
    Enum.reduce((arity - 1)..0//-1, [[]], fn q, tails ->
      choices = if q == position, do: [shape], else: [nil, shape | @valid]
      for choice <- choices, tail <- tails, do: [choice | tail]
    end)
  end

  @events (for(
             kind <- [:query, :prepare, :export],
             stage <- [:start, :stop, :exception],
             do: [:sediment, kind, stage]
           ) ++
             for(
               op <- [:refresh, :snapshot, :restore, :import, :destroy, :flush],
               stage <- [:start, :stop, :exception],
               do: [:sediment, :s3, op, stage]
             )) ++ [[:sediment, :connection, :disconnect]]

  @doc false
  def forward(event, measurements, metadata, test),
    do: send(test, {:telemetry, event, measurements, metadata})

  # The telemetry events emitted meanwhile, without the caller's own values
  # (SQL, parameters, paths).
  defp events do
    receive do
      {:telemetry, event, measurements, metadata} ->
        metadata =
          Map.drop(metadata, [:query, :params, :database, :path, :source, :dest])

        [inspect({event, measurements, metadata}, limit: :infinity) | events()]
    after
      0 -> []
    end
  end

  defp windows(key), do: for(i <- 0..(byte_size(key) - 16), do: binary_part(key, i, 16))

  test "no documented function or configuration callback shows a key, in any shape" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Adapter)

    documented =
      for {{:function, name, arity}, _, _, doc, _} <- docs,
          doc != :hidden,
          do: {name, arity}

    assert {:dump_cmd, 3} in documented
    assert {:s3_refresh, 1} in documented

    handler = {__MODULE__, self()}
    :telemetry.attach_many(handler, @events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    Process.flag(:trap_exit, true)

    {_, log} =
      ExUnit.CaptureLog.with_log(fn ->
        for {name, arity} <- documented ++ @callbacks,
            key <- [@k1, String.duplicate("6e", 16)],
            position <- 0..(arity - 1),
            shape <- shapes(key) ++ configs(key),
            args <- fills(arity, position, shape) do
          {_outcome, texts} = shown(fn -> apply(Adapter, name, args) end)

          for text <- texts ++ events(), window <- windows(key) do
            refute text =~ window, "#{name}/#{arity}, argument #{position + 1}"
          end
        end
      end)

    for key <- [@k1, String.duplicate("6e", 16)], window <- windows(key) do
      refute log =~ window, "the log shows a key"
    end
  end

  # Ecto's own configuration errors keep their message through the
  # boundary (still under the net, without stack arguments).
  test "Ecto's configuration errors say why; a key still never shows" do
    base = [database: ":memory:", telemetry_prefix: [:review]]

    assert_raise RuntimeError, ~r/invalid value for :log option/, fn ->
      Adapter.init(base ++ [log: :verbose])
    end

    for config <- [
          base ++ [encryption: ring(), log: String.to_atom(@k1)],
          base ++ [encryption: ring(), log: :verbose, pool: ring()],
          base ++ [encryption: ring(), pool: String.to_atom(@k1)]
        ] do
      refute_shown(fn -> Adapter.init(config) end, "init/1")
    end

    Process.flag(:trap_exit, true)

    assert {:error, {%RuntimeError{message: message}, _}} =
             DynamicRepo.start_link(name: nil, log: :verbose, database: ":memory:")

    assert message =~ "invalid value for :log option"
  end

  test "a repo started with a key in the wrong place of its configuration never shows it" do
    Process.flag(:trap_exit, true)

    for {case, config} <- [
          {"pool: ring", [pool: ring()]},
          {"pool: a key", [pool: String.to_atom(@k1)]},
          {"pool_size: a key", [pool_size: @k1]},
          {"queue_target: a ring", [queue_target: ring()]}
        ] do
      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          shown(fn ->
            DynamicRepo.start_link(
              [name: nil, log: false, database: ":memory:", encryption: ring()] ++
                config
            )
          end)
        end)

      {outcome, texts} = result
      assert outcome != :ok, "#{case}: accepted"

      exits =
        for {:EXIT, _pid, reason} <- flush_messages(),
            do: inspect(reason, limit: :infinity)

      refute_keys(texts ++ exits ++ [log], case)
    end
  end

  defp flush_messages do
    receive do
      message -> [message | flush_messages()]
    after
      0 -> []
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
