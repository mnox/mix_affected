defmodule SingleApp.Direct do
  @moduledoc "Depends directly (runtime call) on SingleApp.Leaf."
  def value, do: SingleApp.Leaf.value() + 1
end
