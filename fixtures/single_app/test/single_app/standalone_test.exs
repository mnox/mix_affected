defmodule SingleApp.StandaloneTest do
  use ExUnit.Case, async: true

  test "value", do: assert(SingleApp.Standalone.value() == :standalone)
end
