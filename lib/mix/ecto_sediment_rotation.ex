defmodule Mix.EctoSediment.Rotation do
  @moduledoc false
  # What the key rotation tasks share: one outcome line per repo, and a
  # non-zero exit when any repo's result isn't {:ok, _}.

  import Mix.Ecto

  @doc false
  def run(task, args, switches, fun) do
    {opts, positional} =
      OptionParser.parse!(args,
        strict:
          switches ++
            [repo: [:string, :keep], no_compile: :boolean, no_deps_check: :boolean],
        aliases: [r: :repo]
      )

    Mix.Task.run("app.config", args)
    {:ok, _} = Application.ensure_all_started(:sediment)

    repos =
      case parse_repo(args) do
        [] -> Mix.raise("#{task} needs a repo (-r)")
        repos -> repos
      end

    failed =
      for repo <- repos,
          ensure_repo(repo, []),
          result = fun.(repo, opts, positional),
          not match?({:ok, _}, result),
          do: repo

    if failed != [] do
      Mix.raise(
        "#{task}: #{length(failed)} of #{length(repos)} repos failed " <>
          "(#{Enum.map_join(failed, ", ", &inspect/1)}); see above"
      )
    end
  end

  @doc false
  def info(message), do: Mix.shell().info(message)

  @doc false
  def error(message), do: Mix.shell().error(message)

  @doc false
  def reason(reason) when is_binary(reason), do: reason
  def reason(reason), do: inspect(reason)
end
