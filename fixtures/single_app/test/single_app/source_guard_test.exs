defmodule SingleApp.SourceGuardTest do
  # The shape of a source-scanning guard: it reads lib/ with Path.wildcard and
  # File.read! and references no module of the code it guards.
  use ExUnit.Case, async: true

  @roots ["lib/single_app/guarded"]

  @banned ~r/metadata\["origin"\]/

  test "guarded code reads no raw metadata" do
    violations =
      @roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.filter(&(File.read!(&1) =~ @banned))

    assert violations == []
  end
end
