defmodule MixAffected.ReportTest do
  use ExUnit.Case, async: true

  alias MixAffected.Report

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mix_affected_report_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # ExUnit prunes manifest entries whose test file no longer exists.
    for file <- ["test/a_test.exs", "test/b_test.exs"] do
      File.mkdir_p!(Path.join(dir, "test"))
      File.write!(Path.join(dir, file), "")
    end

    %{root: dir, manifest: Path.join([dir, "_build", ".mix_test_failures"])}
  end

  defp selection(full_run, tests),
    do: %{
      "schema_version" => 1,
      "full_run" => full_run,
      "tests" => tests,
      "total_test_files" => 10
    }

  # Written by ExUnit's own writer, so the fixture is the real on-disk format.
  defp write_failures(path, failures) do
    failures
    |> Enum.reduce(ExUnit.FailuresManifest.new(), fn {module, name, file}, acc ->
      ExUnit.FailuresManifest.put_test(acc, %ExUnit.Test{
        module: module,
        name: name,
        state: {:failed, []},
        tags: %{file: file}
      })
    end)
    |> ExUnit.FailuresManifest.write!(path)
  end

  test "missed files are failed files the selection did not include", %{
    root: root,
    manifest: manifest
  } do
    write_failures(manifest, [
      {A, :"test a", "#{root}/test/a_test.exs"},
      {B, :"test b1", "#{root}/test/b_test.exs"},
      {B, :"test b2", "#{root}/test/b_test.exs"}
    ])

    assert {report, []} = Report.build(selection(false, ["test/a_test.exs"]), manifest, root)

    assert report == %{
             schema_version: 1,
             selection_full_run: false,
             failed_files: ["test/a_test.exs", "test/b_test.exs"],
             missed_files: ["test/b_test.exs"],
             selected_count: 1,
             total_test_files: 10
           }
  end

  test "a full-run selection never misses", %{root: root, manifest: manifest} do
    write_failures(manifest, [{B, :"test b", "#{root}/test/b_test.exs"}])

    assert {%{missed_files: [], failed_files: ["test/b_test.exs"]}, []} =
             Report.build(selection(true, []), manifest, root)
  end

  test "a missing manifest reports no failures with a warning", %{root: root, manifest: manifest} do
    assert {%{failed_files: [], missed_files: []}, [warning]} =
             Report.build(selection(false, []), manifest, root)

    assert warning =~ "no failures manifest"
  end

  test "a suite-crash or unknown manifest reports no failures with a warning", %{
    root: root,
    manifest: manifest
  } do
    ExUnit.FailuresManifest.fail_all!(manifest)
    assert {%{failed_files: []}, [warning]} = Report.build(selection(false, []), manifest, root)
    assert warning =~ "whole suite"

    File.write!(manifest, :erlang.term_to_binary({99, %{}}))
    assert {%{failed_files: []}, [warning]} = Report.build(selection(false, []), manifest, root)
    assert warning =~ "unknown"
  end
end
