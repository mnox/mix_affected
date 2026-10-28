defmodule MixAffected.TestMapTest do
  use ExUnit.Case, async: true

  alias MixAffected.TestMap

  @root Path.expand("../../fixtures/single_app", __DIR__)
  @test "test/single_app/direct_test.exs"
  @ref "lib/single_app/direct.ex"

  defp hash(path), do: TestMap.hash(File.read!(Path.join(@root, path)))

  # The shape the builder writes.
  defp entry(hashes),
    do: %{mode: :tracer, refs: [@ref], affected_by: [], hashes: hashes, unresolved: [], reads: []}

  describe "stale/2 and mark_stale/2" do
    test "an entry whose test file and refs are unchanged is fresh and keeps its mode" do
      map = TestMap.new(%{@test => entry(%{@test => hash(@test), @ref => hash(@ref)})})
      assert TestMap.stale(map, @root) == []
      assert TestMap.mark_stale(map, []).tests[@test].mode == :tracer
    end

    test "a changed test file, a changed ref or a missing file makes the entry stale and always-run" do
      for hashes <- [
            %{@test => "stale", @ref => hash(@ref)},
            %{@test => hash(@test), @ref => "stale"},
            %{@test => hash(@test), @ref => hash(@ref), "lib/single_app/gone.ex" => "x"}
          ] do
        map = TestMap.new(%{@test => entry(hashes)})
        assert TestMap.stale(map, @root) == [@test]
        assert %{mode: :always, refs: [@ref]} = TestMap.mark_stale(map, [@test]).tests[@test]
      end
    end
  end

  test "write!/2 and read/1 round-trip; an older format version is unknown_format" do
    path = Path.join(System.tmp_dir!(), "mix_affected_map_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    map = TestMap.new(%{@test => entry(%{@test => "h"})})
    TestMap.write!(map, path)
    assert TestMap.read(path) == {:ok, map}

    # v2 entries have no :reads.
    File.write!(path, :erlang.term_to_binary({TestMap, 2, %{tests: %{}, impls: []}}))
    assert TestMap.read(path) == {:error, "unknown_format"}
  end

  test "a fresh VM that has loaded no other module of ours reads a map" do
    # `:safe` decoding refuses atoms the VM has never seen: the entry keys
    # must not depend on which other modules happen to be loaded.
    path = Path.join(System.tmp_dir!(), "mix_affected_map_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    TestMap.write!(TestMap.new(%{@test => entry(%{@test => "h"})}), path)

    ebin = Application.app_dir(:mix_affected, "ebin")
    read = "IO.write(inspect(MixAffected.TestMap.read(System.argv() |> hd()) |> elem(0)))"
    assert {":ok", 0} = System.cmd("elixir", ["-pa", ebin, "-e", read, path])
  end

  test "a map whose entries lack a field selection relies on is unknown_format" do
    path = Path.join(System.tmp_dir!(), "mix_affected_map_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    entry = Map.delete(entry(%{}), :reads)

    File.write!(
      path,
      :erlang.term_to_binary({TestMap, 3, %{tests: %{@test => entry}, impls: []}})
    )

    assert TestMap.read(path) == {:error, "unknown_format"}
  end
end
