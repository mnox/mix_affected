defmodule SingleApp.LeafTest do
  use ExUnit.Case, async: true

  test "value", do: assert(SingleApp.Leaf.value() == 1)
end
