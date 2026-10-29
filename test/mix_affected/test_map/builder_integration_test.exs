defmodule MixAffected.TestMap.BuilderIntegrationTest do
  # Real fixture compile + real `mix affected.map` (compiler tracer) runs.
  use ExUnit.Case, async: false

  alias MixAffected.FixtureProject
  alias MixAffected.TestMap

  @map "_build/test/mix_affected/test_map.etf"

  defp build_map!(dir) do
    result = FixtureProject.mix(dir, ["affected.map"])
    assert result.status == 0, result.stderr
    {:ok, map} = TestMap.read(Path.join(dir, @map))
    {map, result}
  end

  setup_all do
    dir = FixtureProject.compiled!("single_app")
    {map, result} = build_map!(dir)
    %{map: map, log: result.stderr}
  end

  test "maps every test file through the tracer without running any test", %{map: map, log: log} do
    assert map_size(map.tests) == 15
    assert Enum.all?(map.tests, fn {_file, entry} -> entry.mode == :tracer end)
    assert log =~ "test map of 15 test files (tracer 15, ast 0, always 0)"
    refute log =~ "tests, 0 failures"
  end

  test "records the sources of referenced modules, through aliases and structs", %{map: map} do
    assert map.tests["test/single_app/leaf_test.exs"].refs == ["lib/single_app/leaf.ex"]
    assert map.tests["test/single_app/direct_test.exs"].refs == ["lib/single_app/direct.ex"]

    assert map.tests["test/single_app/user_name_test.exs"].refs ==
             ["lib/single_app/user.ex", "lib/single_app/user_name.ex"]
  end

  test "records test/support modules and modules defined in other test files", %{map: map} do
    assert map.tests["test/single_app/factory_test.exs"].refs == ["test/support/user_factory.ex"]

    assert map.tests["test/single_app/uses_helpers_test.exs"].refs ==
             ["test/single_app/helpers_test.exs"]

    assert map.tests["test/single_app/helpers_test.exs"].refs == ["lib/single_app/rally.ex"]
  end

  test "hashes each test file and every file it references, as built", %{map: map} do
    hash = &TestMap.hash(File.read!(Path.join(FixtureProject.fixture_path("single_app"), &1)))

    assert map.tests["test/single_app/uses_helpers_test.exs"].hashes == %{
             "test/single_app/uses_helpers_test.exs" =>
               hash.("test/single_app/uses_helpers_test.exs"),
             "test/single_app/helpers_test.exs" => hash.("test/single_app/helpers_test.exs")
           }
  end

  test "records referenced modules that resolve to nothing loadable", %{map: map} do
    assert Enum.all?(map.tests, fn {_file, entry} -> entry.unresolved == [] end)

    dir = FixtureProject.compiled!("single_app")
    File.rm!(Path.join(dir, "test/single_app/helpers_test.exs"))
    {map, _result} = build_map!(dir)

    assert map.tests["test/single_app/uses_helpers_test.exs"].unresolved ==
             ["SingleApp.TestHelpers"]
  end

  test "records the repo files a test reads itself, and none for tests that read no files",
       %{map: map} do
    assert map.tests["test/single_app/source_guard_test.exs"].reads ==
             ["lib/single_app/guarded", "lib/single_app/guarded/**"]

    for {file, entry} <- map.tests,
        file != "test/single_app/source_guard_test.exs",
        do: assert(entry.reads == [], file)
  end

  test "records each project protocol impl with the file of the type it is for", %{map: map} do
    assert map.impls == [{"lib/single_app/bag_enumerable.ex", "lib/single_app/bag.ex"}]
  end

  test "reads literal @affected_by and @moduletag affected_by: globs", %{map: map} do
    assert map.tests["test/single_app/dynamic_test.exs"].affected_by == ["lib/single_app/pong.ex"]

    assert map.tests["test/single_app/tagged_test.exs"].affected_by ==
             ["lib/single_app/standalone.ex"]

    assert map.tests["test/single_app/leaf_test.exs"].affected_by == []
  end

  test "an affected_by glob that is malformed or names a directory makes only its test always run, with a warning" do
    dir = FixtureProject.compiled!("single_app")

    File.write!(Path.join(dir, "test/single_app/brace_test.exs"), """
    defmodule SingleApp.BraceTest do
      use ExUnit.Case, async: true
      @moduletag affected_by: ["lib/single_app/{pong,ping.ex", "lib/single_app/leaf.ex"]

      test "x", do: assert(SingleApp.Leaf.value())
    end
    """)

    File.write!(Path.join(dir, "test/single_app/dir_test.exs"), """
    defmodule SingleApp.DirTest do
      use ExUnit.Case, async: true
      @moduletag affected_by: ["lib/single_app/guarded"]

      test "x", do: assert(SingleApp.Leaf.value())
    end
    """)

    File.write!(Path.join(dir, "test/single_app/slash_test.exs"), """
    defmodule SingleApp.SlashTest do
      use ExUnit.Case, async: true
      @moduletag affected_by: ["lib/single_app/**/"]

      test "x", do: assert(SingleApp.Leaf.value())
    end
    """)

    File.write!(Path.join(dir, "test/single_app/dot_test.exs"), """
    defmodule SingleApp.DotTest do
      use ExUnit.Case, async: true
      @moduletag affected_by: ["lib/single_app/./**"]

      test "x", do: assert(SingleApp.Leaf.value())
    end
    """)

    {map, result} = build_map!(dir)

    assert %{mode: :always, affected_by: []} = map.tests["test/single_app/dot_test.exs"]

    assert result.stderr =~
             ~r/mix_affected: warning: test\/single_app\/dot_test\.exs: .*"lib\/single_app\/\*\*".*always runs/

    assert %{mode: :always, affected_by: ["lib/single_app/leaf.ex"]} =
             map.tests["test/single_app/brace_test.exs"]

    assert %{mode: :always, affected_by: []} = map.tests["test/single_app/slash_test.exs"]

    assert result.stderr =~
             ~r/mix_affected: warning: test\/single_app\/slash_test\.exs: .*"lib\/single_app\/\*\*".*always runs/

    assert %{mode: :always, affected_by: []} = map.tests["test/single_app/dir_test.exs"]
    assert map.tests["test/single_app/tagged_test.exs"].mode == :tracer

    assert result.stderr =~
             ~r/mix_affected: warning: test\/single_app\/brace_test\.exs: .*"lib\/single_app\/\{pong,ping\.ex".*always runs/

    assert result.stderr =~
             ~r/mix_affected: warning: test\/single_app\/dir_test\.exs: .*"lib\/single_app\/guarded\/\*\*".*always runs/

    assert result.stderr =~ "(tracer 15, ast 0, always 4)"
  end

  test "a test file that fails to require falls back to its AST; an unparseable one always runs" do
    dir = FixtureProject.compiled!("single_app")

    File.write!(Path.join(dir, "test/single_app/raises_test.exs"), """
    defmodule SingleApp.RaisesTest do
      use ExUnit.Case
      alias SingleApp.Standalone

      test "x", do: assert(Standalone.value())
    end

    raise "fails at require time"
    """)

    File.write!(Path.join(dir, "test/single_app/unparseable_test.exs"), "defmodule Broken do\n")

    {map, _result} = build_map!(dir)

    assert %{mode: :ast, refs: refs} = map.tests["test/single_app/raises_test.exs"]
    assert "lib/single_app/standalone.ex" in refs
    assert map.tests["test/single_app/unparseable_test.exs"].mode == :always
    # Files compiling fine next to the broken ones still get traced.
    assert %{mode: :tracer, refs: ["lib/single_app/leaf.ex"], affected_by: []} =
             map.tests["test/single_app/leaf_test.exs"]
  end
end
