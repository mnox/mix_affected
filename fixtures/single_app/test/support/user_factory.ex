defmodule SingleApp.UserFactory do
  @moduledoc "Test-support module compiled only in the test env."
  def build, do: %SingleApp.User{name: "fixture"}
end
