defmodule MixAffected.Graph.Source.XrefJsonParseTest do
  use ExUnit.Case, async: true

  alias MixAffected.Graph.Source.XrefJson

  test "rejects JSON that is not a two-level map of edge kinds" do
    assert {:error, {:parse_error, _}} = XrefJson.parse(~s({"lib/a.ex": {"lib/b.ex": "weird"}}))
    assert {:error, {:parse_error, _}} = XrefJson.parse(~s(["lib/a.ex"]))
    assert {:error, {:parse_error, _}} = XrefJson.parse("not json")
  end
end
