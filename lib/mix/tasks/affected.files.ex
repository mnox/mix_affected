defmodule Mix.Tasks.Affected.Files do
  @shortdoc "Prints the test files affected by a change set"

  @moduledoc """
  Prints the test files a change set may affect. Run with `MIX_ENV=test`.

      mix affected.files --base origin/main
      git diff --name-only origin/main... | mix affected.files --files -
      mix affected.files --files changed.txt --format json --output selection.json

  Input, exactly one of:

    * `--base <git-ref>` - files changed on `<ref>...HEAD`, plus uncommitted
      and untracked files (needs `.git`)
    * `--files <path|->` - newline-separated project-relative paths; `-`
      reads stdin

  Options:

    * `--format text|json` - text (default) prints one test file per line; on
      a full run it prints nothing and the reason goes to stderr
    * `--explain` - the chain `changed file -> ... -> test` per selected test
      (text: one chain per line; JSON: the `explain` object)
    * `--output <path>` - write to a file instead of stdout
    * `--map <path>` - the test map to use; built there when missing
      (default `_build/test/mix_affected/test_map.etf`)

  Exit status: 0 on any answer (including a full run and an empty
  selection), 1 on a usage error, 2 when the graph or test map could not be
  built (the output then says `full_run: true`).
  """

  use Mix.Task

  alias MixAffected.CLI

  @impl Mix.Task
  def run(args) do
    MixAffected.load_modules!()

    case CLI.parse_select(args) do
      {:ok, opts} ->
        result = CLI.select!(opts)
        CLI.emit(result, opts)
        CLI.halt_on_failure(result)

      {:error, message} ->
        CLI.usage_error!(message)
    end
  end
end
