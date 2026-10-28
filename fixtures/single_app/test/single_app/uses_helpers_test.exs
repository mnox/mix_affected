defmodule SingleApp.UsesHelpersTest do
  # Sync: ExUnit runs async modules while other test files are still loading,
  # so this could call SingleApp.TestHelpers before helpers_test.exs defines it.
  use ExUnit.Case, async: false

  test "uses a helper defined in another test file",
    do: assert(SingleApp.TestHelpers.rally() == :done)
end
