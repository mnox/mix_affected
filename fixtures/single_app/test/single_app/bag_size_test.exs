defmodule SingleApp.BagSizeTest do
  use ExUnit.Case, async: true

  # References neither SingleApp.Bag nor its impl, only SingleApp.BagSize.
  test "size", do: assert(SingleApp.BagSize.size([:a, :b]) == 2)
end
