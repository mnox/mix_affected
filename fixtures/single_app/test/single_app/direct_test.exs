defmodule SingleApp.DirectTest do
  use ExUnit.Case, async: true

  alias SingleApp.Direct

  test "value", do: assert(Direct.value() == 2)
end
