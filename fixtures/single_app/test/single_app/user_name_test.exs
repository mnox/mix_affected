defmodule SingleApp.UserNameTest do
  use ExUnit.Case, async: true

  test "name", do: assert(SingleApp.UserName.name(%SingleApp.User{name: "a"}) == "a")
end
