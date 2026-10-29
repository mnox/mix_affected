defmodule MixAffected.RunTest do
  use ExUnit.Case, async: true

  alias MixAffected.Config
  alias MixAffected.Graph
  alias MixAffected.Run
  alias MixAffected.TestMap

  @root Path.expand("../../fixtures/single_app", __DIR__)

  defp graph do
    Graph.new(@root, %{
      "lib/single_app/leaf.ex" => %{},
      "lib/single_app/direct.ex" => %{"lib/single_app/leaf.ex" => :runtime}
    })
  end

  defp map do
    TestMap.new(%{
      "test/single_app/direct_test.exs" =>
        entry("test/single_app/direct_test.exs", ["lib/single_app/direct.ex"]),
      "test/single_app/leaf_test.exs" => entry("test/single_app/leaf_test.exs", [])
    })
  end

  # An entry as the builder writes it: hashes of the test file and its refs
  # as they are on disk now.
  defp entry(test, refs) do
    hashes = Map.new([test | refs], &{&1, TestMap.hash(File.read!(Path.join(@root, &1)))})
    %{mode: :tracer, refs: refs, affected_by: [], hashes: hashes}
  end

  defp run(changed, overrides) do
    {:ok, config} = Config.from_project([], @root)

    opts =
      Keyword.merge(
        [
          root: @root,
          config: config,
          test_files: ["test/single_app/direct_test.exs", "test/single_app/leaf_test.exs"],
          graph_source: "xref_dot",
          graph: fn -> {:ok, graph()} end,
          test_map: fn -> {:ok, map()} end
        ],
        overrides
      )

    Run.run(changed, opts)
  end

  defp refuse(what), do: fn -> flunk("#{what} must not be consulted") end

  test "selects through graph and map, reporting changed, affected and totals" do
    result = run(["lib/single_app/leaf.ex"], [])

    assert %{full_run: false, reason: nil, exit_status: 0} = result
    assert result.changed_files == ["lib/single_app/leaf.ex"]
    assert result.affected_files == ["lib/single_app/direct.ex", "lib/single_app/leaf.ex"]
    assert result.tests == ["test/single_app/direct_test.exs"]
    assert result.total_test_files == 2
    assert result.graph_source == "xref_dot"

    assert result.explain["test/single_app/direct_test.exs"] ==
             [
               "lib/single_app/leaf.ex",
               "lib/single_app/direct.ex",
               "test/single_app/direct_test.exs"
             ]
  end

  test "a non-canonical path seeds the selection by its canonical path" do
    result = run(["lib/./single_app/leaf.ex"], [])
    assert result.changed_files == ["lib/single_app/leaf.ex"]
    assert result.tests == ["test/single_app/direct_test.exs"]
  end

  test "a deleted test file selects the tests that used modules it defined" do
    map =
      TestMap.new(%{
        "test/single_app/leaf_test.exs" => %{
          entry("test/single_app/leaf_test.exs", [])
          | refs: ["test/single_app/gone_helpers_test.exs"]
        },
        "test/single_app/direct_test.exs" => entry("test/single_app/direct_test.exs", [])
      })

    result =
      run(["test/single_app/gone_helpers_test.exs"],
        graph: refuse("graph"),
        test_map: fn -> {:ok, map} end
      )

    assert result.tests == ["test/single_app/leaf_test.exs"]

    assert result.explain["test/single_app/leaf_test.exs"] ==
             ["test/single_app/gone_helpers_test.exs", "test/single_app/leaf_test.exs"]
  end

  test "a selected entry whose test file changed since the map was built is a full run" do
    # Its refs may be out of date: a helper-defining test file it now needs
    # could be missing from the selection.
    stale =
      put_in(
        map().tests["test/single_app/leaf_test.exs"].hashes["test/single_app/leaf_test.exs"],
        "old"
      )

    result = run(["lib/single_app/leaf.ex"], test_map: fn -> {:ok, stale} end)

    assert %{
             full_run: true,
             reason: "test_map_unavailable:stale_entry:test/single_app/leaf_test.exs",
             exit_status: 2,
             tests: []
           } = result
  end

  test "a test file the map does not know is a full run" do
    result =
      run(["lib/single_app/leaf.ex"],
        test_files: [
          "test/single_app/direct_test.exs",
          "test/single_app/leaf_test.exs",
          "test/single_app/standalone_test.exs"
        ]
      )

    assert %{
             full_run: true,
             reason: "test_map_unavailable:stale_entry:test/single_app/standalone_test.exs",
             exit_status: 2
           } = result
  end

  test "an ignored-only change builds no graph and selects only the tests that read the file" do
    reader = Map.put(entry("test/single_app/leaf_test.exs", []), :reads, ["README.md"])
    map = TestMap.new(Map.put(map().tests, "test/single_app/leaf_test.exs", reader))

    result = run(["README.md"], graph: refuse("graph"), test_map: fn -> {:ok, map} end)
    assert %{full_run: false, tests: ["test/single_app/leaf_test.exs"], exit_status: 0} = result

    assert result.explain["test/single_app/leaf_test.exs"] == [
             "README.md",
             "test/single_app/leaf_test.exs"
           ]

    result = run(["docs/guide.md"], graph: refuse("graph"), test_map: fn -> {:ok, map} end)
    assert %{full_run: false, tests: [], affected_files: [], exit_status: 0} = result
  end

  test "a global invalidation is a full run without building graph or map" do
    result = run(["mix.lock"], graph: refuse("graph"), test_map: refuse("test map"))

    assert %{full_run: true, reason: "global_invalidation:mix.lock:mix.lock", exit_status: 0} =
             result

    assert result.tests == []
  end

  test "a graph failure is a full run with exit status 2" do
    {result, log} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        run(["lib/single_app/leaf.ex"], graph: fn -> {:error, {:xref_failed, 1, "boom"}} end)
      end)

    assert log =~ "boom"
    assert %{full_run: true, reason: "graph_unavailable:xref_failed:1", exit_status: 2} = result
  end

  test "a test map failure is a full run with exit status 2" do
    result = run(["lib/single_app/leaf.ex"], test_map: fn -> {:error, "unknown_format"} end)

    assert %{full_run: true, reason: "test_map_unavailable:unknown_format", exit_status: 2} =
             result
  end

  test "a source the graph does not compile is a full run with exit status 0" do
    result = run(["lib/single_app/macros.ex"], test_map: refuse("test map"))

    assert %{full_run: true, reason: "unmapped_file:lib/single_app/macros.ex", exit_status: 0} =
             result
  end
end
