defmodule SingleApp.TaggedTest do
  use ExUnit.Case, async: true

  # Reached only through a runtime-built module name; the @moduletag form
  # needs no attribute registration and may share the keyword with other tags.
  @moduletag slow: false, affected_by: ["lib/single_app/standalone.ex"]

  test "dispatches dynamically" do
    module = Module.concat(["SingleApp", "Standalone"])
    assert module.value() == :standalone
  end
end
