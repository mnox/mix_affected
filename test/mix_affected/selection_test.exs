defmodule MixAffected.SelectionTest do
  use ExUnit.Case, async: true

  alias MixAffected.Config
  alias MixAffected.Graph
  alias MixAffected.Selection
  alias MixAffected.TestMap

  # c.ex <- b.ex <- a.ex, and c.ex <- a.ex directly (shorter), d.ex standalone.
  defp graph do
    Graph.new("/repo", %{
      "lib/a.ex" => %{"lib/b.ex" => :runtime, "lib/c.ex" => :runtime},
      "lib/b.ex" => %{"lib/c.ex" => :compile},
      "lib/c.ex" => %{},
      "lib/d.ex" => %{}
    })
  end

  defp config(affected \\ []) do
    {:ok, config} = Config.from_project([affected: affected], "/repo")
    config
  end

  defp entry(refs, opts \\ []),
    do: %{
      mode: Keyword.get(opts, :mode, :tracer),
      refs: refs,
      affected_by: opts[:affected_by] || [],
      hashes: %{},
      unresolved: opts[:unresolved] || [],
      reads: opts[:reads] || []
    }

  defp select(seeds, tests, config \\ config()) do
    Selection.select(graph(), seeds, Map.keys(tests), TestMap.new(tests), config)
  end

  test "a test is selected when a module it references lives in an affected file" do
    result =
      select(["lib/c.ex"], %{
        "test/a_test.exs" => entry(["lib/a.ex"]),
        "test/d_test.exs" => entry(["lib/d.ex"])
      })

    assert result.tests == ["test/a_test.exs"]
  end

  test "explain gives one shortest chain from a changed file to the test" do
    result = select(["lib/c.ex"], %{"test/a_test.exs" => entry(["lib/a.ex"])})
    assert result.explain == %{"test/a_test.exs" => ["lib/c.ex", "lib/a.ex", "test/a_test.exs"]}
  end

  test "a changed test is selected with itself as its chain" do
    result = select(["test/d_test.exs"], %{"test/d_test.exs" => entry(["lib/d.ex"])})
    assert result.tests == ["test/d_test.exs"]
    assert result.explain == %{"test/d_test.exs" => ["test/d_test.exs"]}
  end

  test "@affected_by globs select a test when they match an affected file" do
    tests = %{
      "test/dynamic_test.exs" => entry([], affected_by: ["lib/{b,x}.ex"]),
      "test/other_test.exs" => entry([], affected_by: ["lib/d.ex"])
    }

    result = select(["lib/c.ex"], tests)
    assert result.tests == ["test/dynamic_test.exs"]

    assert result.explain["test/dynamic_test.exs"] == [
             "lib/c.ex",
             "lib/b.ex",
             "test/dynamic_test.exs"
           ]
  end

  test "config mappings select matching tests when the source glob matches an affected file" do
    tests = %{
      "test/workers/a_test.exs" => entry([]),
      "test/workers/b_test.exs" => entry([]),
      "test/web/c_test.exs" => entry([])
    }

    result = select(["lib/d.ex"], tests, config(mappings: [{"lib/d.ex", ["test/workers/**"]}]))
    assert result.tests == ["test/workers/a_test.exs", "test/workers/b_test.exs"]
    assert result.explain["test/workers/a_test.exs"] == ["lib/d.ex", "test/workers/a_test.exs"]
  end

  test "a changed test file that defines helpers selects the tests referencing it" do
    tests = %{
      "test/helpers_test.exs" => entry(["lib/d.ex"]),
      "test/uses_helpers_test.exs" => entry(["test/helpers_test.exs"]),
      "test/unrelated_test.exs" => entry(["lib/a.ex"])
    }

    result = select(["test/helpers_test.exs"], tests)
    assert result.tests == ["test/helpers_test.exs", "test/uses_helpers_test.exs"]

    assert result.explain["test/uses_helpers_test.exs"] ==
             ["test/helpers_test.exs", "test/uses_helpers_test.exs"]
  end

  test "a deleted test file selects tests referencing modules that no longer exist" do
    # Map built after the deletion: the helper module no longer resolves.
    tests = %{
      "test/uses_helpers_test.exs" => entry([], unresolved: ["MyApp.TestHelpers"]),
      "test/unrelated_test.exs" => entry(["lib/a.ex"])
    }

    result = select(["test/helpers_test.exs"], tests)
    assert result.tests == ["test/uses_helpers_test.exs"]

    assert result.explain["test/uses_helpers_test.exs"] ==
             ["test/helpers_test.exs", "test/uses_helpers_test.exs"]
  end

  test "a changed source selects tests referencing modules that no longer exist" do
    # Map built after lib/d.ex dropped a module the test still calls.
    tests = %{
      "test/uses_gone_test.exs" => entry([], unresolved: ["MyApp.Gone"]),
      "test/unrelated_test.exs" => entry(["lib/a.ex"])
    }

    result = select(["lib/d.ex"], tests)
    assert result.tests == ["test/uses_gone_test.exs"]
    assert result.explain["test/uses_gone_test.exs"] == ["lib/d.ex", "test/uses_gone_test.exs"]
  end

  test "a changed test file selects tests referencing modules that no longer exist" do
    # Map built after helpers_test.exs dropped the helper module but kept its tests.
    tests = %{
      "test/helpers_test.exs" => entry(["lib/d.ex"]),
      "test/uses_helpers_test.exs" => entry([], unresolved: ["MyApp.TestHelpers"]),
      "test/unrelated_test.exs" => entry(["lib/a.ex"])
    }

    result = select(["test/helpers_test.exs"], tests)
    assert result.tests == ["test/helpers_test.exs", "test/uses_helpers_test.exs"]

    assert result.explain["test/uses_helpers_test.exs"] ==
             ["test/helpers_test.exs", "test/uses_helpers_test.exs"]
  end

  test "selection propagates through modules defined in test files" do
    tests = %{
      "test/helpers_test.exs" => entry(["lib/d.ex"]),
      "test/uses_helpers_test.exs" => entry(["test/helpers_test.exs"])
    }

    result = select(["lib/d.ex"], tests)
    assert result.tests == ["test/helpers_test.exs", "test/uses_helpers_test.exs"]

    assert result.explain["test/uses_helpers_test.exs"] ==
             ["lib/d.ex", "test/helpers_test.exs", "test/uses_helpers_test.exs"]
  end

  test "a selected test pulls in the test files defining modules it uses, so it can run alone" do
    tests = %{
      "test/helpers_test.exs" => entry([]),
      "test/uses_helpers_test.exs" => entry(["lib/d.ex", "test/helpers_test.exs"])
    }

    result = select(["lib/d.ex"], tests)
    assert result.tests == ["test/helpers_test.exs", "test/uses_helpers_test.exs"]

    assert result.explain["test/helpers_test.exs"] ==
             ["lib/d.ex", "test/uses_helpers_test.exs", "test/helpers_test.exs"]
  end

  test "tests the map marks always-run, or does not know, run whenever anything is affected" do
    known = %{
      "test/broken_test.exs" => entry([], mode: :always),
      "test/d_test.exs" => entry(["lib/d.ex"])
    }

    files = ["test/broken_test.exs", "test/d_test.exs", "test/new_test.exs"]

    result = Selection.select(graph(), ["lib/c.ex"], files, TestMap.new(known), config())
    assert result.tests == ["test/broken_test.exs", "test/new_test.exs"]
    assert result.explain["test/new_test.exs"] == ["test/new_test.exs"]

    assert Selection.select(graph(), [], files, TestMap.new(known), config()).tests == []
  end

  test "AST-fallback entries run whenever anything is affected: use-injected refs are unseen" do
    known = %{
      "test/fallback_test.exs" => entry(["lib/d.ex"], mode: :ast),
      "test/d_test.exs" => entry(["lib/d.ex"])
    }

    files = Map.keys(known)
    result = Selection.select(graph(), ["lib/c.ex"], files, TestMap.new(known), config())
    assert result.tests == ["test/fallback_test.exs"]
    assert result.explain["test/fallback_test.exs"] == ["test/fallback_test.exs"]
  end

  test "map entries for test files that no longer exist are never selected" do
    tests = %{
      "test/gone_test.exs" => entry(["lib/c.ex"]),
      "test/a_test.exs" => entry(["lib/a.ex"])
    }

    result =
      Selection.select(graph(), ["lib/c.ex"], ["test/a_test.exs"], TestMap.new(tests), config())

    assert result.tests == ["test/a_test.exs"]
  end

  test "works without a graph when only test files changed" do
    tests = %{"test/a_test.exs" => entry(["lib/a.ex"])}

    result =
      Selection.select(
        nil,
        ["test/a_test.exs"],
        ["test/a_test.exs"],
        TestMap.new(tests),
        config()
      )

    assert result.tests == ["test/a_test.exs"]
  end

  test "a test that reads a changed file is selected; one whose read file is only affected is not" do
    tests = %{
      "test/guard_test.exs" => entry([], reads: ["lib/b.ex", "lib/b.ex/**"]),
      "test/a_test.exs" => entry(["lib/a.ex"])
    }

    result = select(["lib/b.ex"], tests)
    assert result.tests == ["test/a_test.exs", "test/guard_test.exs"]
    assert result.explain["test/guard_test.exs"] == ["lib/b.ex", "test/guard_test.exs"]

    # lib/c.ex changes lib/b.ex's dependents, not lib/b.ex's content.
    assert select(["lib/c.ex"], tests).tests == ["test/a_test.exs"]
  end

  test "a read-only seed (an ignored file) selects only the tests that read it" do
    known = %{
      "test/docs_test.exs" => entry([], reads: ["README.md"]),
      "test/broken_test.exs" => entry([], mode: :always),
      "test/d_test.exs" => entry(["lib/d.ex"], affected_by: ["**"])
    }

    files = ["test/new_test.exs" | Map.keys(known)]
    select = &Selection.select(graph(), [], files, TestMap.new(known), config(), &1)

    # An unknown test may read anything: Run turns selecting it into a full run.
    assert select.(["README.md"]).tests == ["test/docs_test.exs", "test/new_test.exs"]

    assert select.(["README.md"]).explain["test/docs_test.exs"] == [
             "README.md",
             "test/docs_test.exs"
           ]

    assert select.(["docs/other.md"]).tests == ["test/new_test.exs"]

    assert Selection.select(graph(), [], Map.keys(known), TestMap.new(known), config(), ["x.md"]).tests ==
             []
  end
end
