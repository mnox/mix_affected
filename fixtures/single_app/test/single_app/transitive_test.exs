defmodule SingleApp.TransitiveTest do
  use ExUnit.Case, async: true

  test "value", do: assert(SingleApp.Transitive.value() == 3)
end
