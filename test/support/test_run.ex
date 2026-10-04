defmodule EctoSediment.TestRun do
  @moduledoc false

  # ExUnit's tmp_dir is tmp/<module>/<test>-<hash>, the same for every run in
  # a checkout and emptied when a test starts, so two runs at once (a watcher
  # and `mix ci`) would share and wipe each other's databases. Modules use
  # `@moduletag tmp_dir: EctoSediment.TestRun.tmp_dir()`, a subdirectory of it
  # per OS process; test_helper removes those of runs that are gone.
  def tmp_dir, do: "run-#{System.pid()}"
end
