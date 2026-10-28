defmodule MixAffected.Report do
  @moduledoc """
  Compares a saved selection with the failures of the last full `mix test`.

  ExUnit records failures in its failures manifest, the file
  `mix test --failed` reads: `<Mix.Project.manifest_path()>/.mix_test_failures`
  (or `config :ex_unit, failures_manifest_path:`), holding
  `:erlang.term_to_binary({1, %{{module, test_name} => absolute_test_file}})`,
  or `{1, :all}` when the run crashed (Elixir 1.18 and 1.19:
  see the private ExUnit.FailuresManifest module and `Mix.Tasks.Test`). Any other shape is reported as
  no failures plus a warning: this is shadow data and must never crash CI.
  """

  @doc "The failures manifest `mix test` writes in the current project."
  @spec manifest_path() :: Path.t()
  def manifest_path do
    Application.get_env(:ex_unit, :failures_manifest_path) ||
      Path.join(Mix.Project.manifest_path(), ".mix_test_failures")
  end

  @doc """
  The v1 report for a decoded selection JSON, plus warnings for stderr.
  Failed files are made relative to `root`.
  """
  @spec build(map(), Path.t(), Path.t()) :: {map(), [String.t()]}
  def build(selection, manifest, root) do
    {failed, warnings} = failed_files(manifest, root)
    full_run = selection["full_run"] == true
    selected = selection["tests"] || []

    report = %{
      schema_version: 1,
      selection_full_run: full_run,
      failed_files: failed,
      missed_files: if(full_run, do: [], else: failed -- selected),
      selected_count: length(selected),
      total_test_files: selection["total_test_files"] || 0
    }

    {report, warnings}
  end

  defp failed_files(manifest, root) do
    case read(manifest) do
      {:ok, {1, %{} = failures}} ->
        files = failures |> Map.values() |> Enum.map(&Path.relative_to(&1, root))
        {files |> Enum.uniq() |> Enum.sort(), []}

      {:ok, {1, :all}} ->
        {[],
         [
           "mix_affected: failures manifest marks the whole suite failed (crash); no per-file data"
         ]}

      {:ok, _other} ->
        {[],
         ["mix_affected: unknown failures manifest format at #{manifest}; reporting no failures"]}

      {:error, reason} ->
        {[],
         ["mix_affected: no failures manifest at #{manifest} (#{reason}); reporting no failures"]}
    end
  end

  defp read(manifest) do
    with {:ok, binary} <- File.read(manifest) do
      {:ok, :erlang.binary_to_term(binary)}
    end
  rescue
    ArgumentError -> {:ok, :undecodable}
  end
end
