defmodule SingleApp.DynamicTest do
  use ExUnit.Case, async: true

  # Reached only through a runtime-built module name, which no tracer sees.
  # Registering the attribute keeps it from warning as unused.
  Module.register_attribute(__MODULE__, :affected_by, persist: true)
  @affected_by ["lib/single_app/pong.ex"]

  test "dispatches dynamically" do
    module = Module.concat(["SingleApp", "Pong"])
    assert module.pong(0) == :done
  end
end
