defmodule Mix.Tasks.Affected.Map do
  @shortdoc "Builds the test file -> referenced source files map"

  @moduledoc """
  Builds the test map `mix affected.files` and `mix affected.test` select
  with, at `_build/test/mix_affected/test_map.etf` or `--map <path>`. Those
  tasks build it themselves when it is missing. Run with `MIX_ENV=test`.

  Compiles the project and starts it as `mix test` does, requires
  `test_helper.exs` and every test file with a compiler tracer registered,
  and runs no test. See `MixAffected.TestMap.Builder` for the fallbacks when
  a test file fails to require. A summary goes to stderr.

  Exit status: 0 when written, 1 on a usage error (including an umbrella
  root, which is not supported), 2 when the map could not be built.
  """

  use Mix.Task

  alias MixAffected.CLI
  alias MixAffected.TestMap
  alias MixAffected.TestMap.Builder

  @impl Mix.Task
  def run(args) do
    MixAffected.load_modules!()

    case CLI.parse_map(args) do
      {:ok, %{map: map}} -> build(CLI.map_path(map))
      {:error, message} -> CLI.usage_error!(message)
    end
  end

  defp build(path) do
    if Mix.Project.umbrella?(), do: CLI.usage_error!("umbrella projects are not supported")
    config = CLI.config!()
    started = System.monotonic_time(:millisecond)

    Mix.Task.run("compile")
    start_app()

    root = File.cwd!()
    exclude = [Mix.Project.deps_path(), Mix.Project.build_path()]
    {map, stats} = Builder.build(root, config, exclude: exclude, modules: project_modules())
    TestMap.write!(map, path)

    for error <- stats.helper_errors,
        do: IO.puts(:stderr, "mix_affected: warning: test helper failed: #{error}")

    IO.puts(
      :stderr,
      "mix_affected: test map of #{map_size(map.tests)} test files " <>
        "(tracer #{stats.tracer}, ast #{stats.ast}, always #{stats.always}) " <>
        "written to #{Path.relative_to(path, root)} in #{System.monotonic_time(:millisecond) - started}ms"
    )
  end

  # Every module the project compiled (its .beam files), whether or not the
  # app spec could be loaded.
  defp project_modules do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".beam") |> String.to_atom()))
  end

  # As mix test does; tracing itself only needs the code compiled, so a
  # failure to start is reported, not fatal.
  defp start_app do
    Mix.Task.run("app.start")
  catch
    kind, reason ->
      IO.puts(
        :stderr,
        "mix_affected: warning: app.start failed: #{Exception.format_banner(kind, reason)}"
      )
  end
end
