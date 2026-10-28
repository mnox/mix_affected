defmodule SingleApp.TestHelpers do
  @moduledoc "Helpers defined in a test file and used by other test files."
  def rally, do: SingleApp.Rally.start()
end

defmodule SingleApp.HelpersTest do
  use ExUnit.Case, async: true

  test "rally", do: assert(SingleApp.TestHelpers.rally() == :done)
end
