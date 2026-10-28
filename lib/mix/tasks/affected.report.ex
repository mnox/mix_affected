defmodule Mix.Tasks.Affected.Report do
  @shortdoc "Reports failed test files a saved selection missed"

  @moduledoc """
  After a full `mix test`, compares ExUnit's failures manifest (the file
  `mix test --failed` reads) with a selection saved by `mix affected.files
  --format json`. Run with `MIX_ENV=test`.

      mix affected.report --selection selection.json [--format text|json] [--output path]

  JSON: `schema_version`, `selection_full_run`, `failed_files`,
  `missed_files` (failed files not in the selection; always `[]` for a
  full-run selection), `selected_count`, `total_test_files`. Text: the missed
  files, one per line.

  Exit status 0 whatever the misses (shadow data); 1 on a usage error,
  including an unreadable selection file. An unknown or missing failures
  manifest reports `failed_files: []` and warns on stderr.
  """

  use Mix.Task

  alias MixAffected.CLI
  alias MixAffected.Report

  @impl Mix.Task
  def run(args) do
    MixAffected.load_modules!()

    case CLI.parse_report(args) do
      {:ok, opts} -> report(opts)
      {:error, message} -> CLI.usage_error!(message)
    end
  end

  defp report(opts) do
    selection = read_selection!(opts.selection)
    {report, warnings} = Report.build(selection, Report.manifest_path(), File.cwd!())
    Enum.each(warnings, &IO.puts(:stderr, &1))

    body =
      case opts.format do
        :json -> JSON.encode!(report) <> "\n"
        :text -> Enum.map_join(report.missed_files, &(&1 <> "\n"))
      end

    CLI.write(body, opts.output)

    IO.puts(
      :stderr,
      "mix_affected: #{length(report.missed_files)} missed of #{length(report.failed_files)} failed test files"
    )
  end

  defp read_selection!(path) do
    with {:ok, data} <- File.read(path),
         {:ok, %{"schema_version" => 1} = selection} <- JSON.decode(data) do
      selection
    else
      _ -> CLI.usage_error!("--selection #{path} is not a readable v1 selection JSON")
    end
  end
end
