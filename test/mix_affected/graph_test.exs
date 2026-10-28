defmodule MixAffected.GraphTest do
  use ExUnit.Case, async: true

  alias MixAffected.Graph
  alias MixAffected.Graph.Source

  @root "/repo"

  defp graph do
    Graph.new(@root, %{
      "lib/a.ex" => %{"lib/b.ex" => :runtime},
      "lib/b.ex" => %{"lib/c.ex" => :compile},
      "lib/c.ex" => %{}
    })
  end

  describe "dependents/2" do
    test "refuses to vouch for a changed file the graph does not know" do
      assert Graph.dependents(graph(), ["lib/c.ex", "lib/new.ex", "README.md"]) ==
               {:error, {:unknown_files, ["README.md", "lib/new.ex"]}}
    end

    test "accepts absolute paths under the project root and answers relative paths" do
      assert {:ok, files} = Graph.dependents(graph(), [Path.join(@root, "lib/c.ex")])
      assert Enum.sort(files) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end
  end

  describe "Source.default/1" do
    test "picks the dot adapter before Elixir 1.19 and the JSON adapter from 1.19 on" do
      assert Source.default("1.18.3") == Source.XrefDot
      assert Source.default("1.19.0-rc.1") == Source.XrefDot
      assert Source.default("1.19.5") == Source.XrefJson
      assert Source.default("1.20.0") == Source.XrefJson
    end
  end
end
