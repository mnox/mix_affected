defmodule SingleApp.UsesMacrosTest do
  use ExUnit.Case, async: true

  test "greeting comes from the __using__ macro",
    do: assert(SingleApp.UsesMacros.greeting() == "hello")
end
