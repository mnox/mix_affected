defmodule Mocks.PlainTest do
  use ExUnit.Case, async: true

  test "uses no mock" do
    assert Mocks.Greeter.module_info(:module) == Mocks.Greeter
  end
end
