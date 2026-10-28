defmodule Mocks.GreeterTest do
  use ExUnit.Case, async: true

  import Mox

  test "greets with the configured clock" do
    expect(Mocks.MockClock, :now, fn -> 42 end)
    assert Mocks.Greeter.greet() == "hello at 42"
  end
end
