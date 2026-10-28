defmodule Mix.Tasks.Affected.Test do
  @shortdoc "Runs mix test on the test files affected by a change set"

  @moduledoc """
  Runs `mix test` on the affected test files. Takes the input options of
  `mix affected.files` (`--base` or `--files`, `--map`); everything after
  `--` goes to `mix test` unchanged. Run with `MIX_ENV=test`.

      mix affected.test --base origin/main -- --warnings-as-errors

    * full run (including a graph or test map failure): plain
      `mix test <passthrough>`
    * empty selection: prints `mix_affected: no affected tests` and exits 0
      without starting ExUnit
    * otherwise `mix test <files> <passthrough>`; its exit status is this
      task's

  With `--output <path>` the selection is also written there, in `--format`
  (with `--explain` if given), for `mix affected.report` later. The summary
  line goes to stderr.
  """

  use Mix.Task

  alias MixAffected.CLI
  alias MixAffected.Result

  @impl Mix.Task
  def run(args) do
    MixAffected.load_modules!()

    {own, passthrough} = CLI.split_passthrough(args)

    case CLI.parse_select(own) do
      {:ok, opts} ->
        result = CLI.select!(opts)
        if opts.output, do: CLI.emit(result, opts), else: IO.puts(:stderr, Result.summary(result))
        run_tests(result, passthrough)

      {:error, message} ->
        CLI.usage_error!(message)
    end
  end

  defp run_tests(%Result{full_run: true}, passthrough), do: Mix.Task.run("test", passthrough)

  defp run_tests(%Result{tests: []}, _passthrough) do
    IO.puts("mix_affected: no affected tests")
    :ok
  end

  defp run_tests(%Result{tests: tests}, passthrough),
    do: Mix.Task.run("test", tests ++ passthrough)
end
