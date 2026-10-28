defmodule MixAffected.Graph.Source.XrefDotTest do
  use MixAffected.SourceContract, source: MixAffected.Graph.Source.XrefDot

  alias MixAffected.Graph.Source.XrefDot

  describe "parse/1" do
    test "rejects output that is not an xref dot graph" do
      assert {:error, {:parse_error, _line}} =
               XrefDot.parse(~s|digraph "xref graph" {\n  "lib/a.ex" => "lib/b.ex"\n}\n|)
    end

    test "rejects an edge label it does not know" do
      assert {:error, {:parse_error, _line}} =
               XrefDot.parse(
                 ~s|digraph "xref graph" {\n  "lib/a.ex" -> "lib/b.ex" [label="(weird)"]\n}\n|
               )
    end
  end
end
