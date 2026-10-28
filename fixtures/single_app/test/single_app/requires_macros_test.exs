defmodule SingleApp.RequiresMacrosTest do
  use ExUnit.Case, async: true

  test "four", do: assert(SingleApp.RequiresMacros.four() == 4)
end
