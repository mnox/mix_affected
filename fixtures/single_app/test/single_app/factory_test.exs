defmodule SingleApp.FactoryTest do
  use ExUnit.Case, async: true

  test "build", do: assert(SingleApp.UserFactory.build().name == "fixture")
end
