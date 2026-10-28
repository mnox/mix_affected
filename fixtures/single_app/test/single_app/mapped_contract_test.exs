defmodule SingleApp.MappedContractTest do
  use ExUnit.Case, async: true

  # Selected through the project's `affected: [mappings: ...]` only.
  test "contract", do: assert(Application.get_application(__MODULE__) == nil)
end
