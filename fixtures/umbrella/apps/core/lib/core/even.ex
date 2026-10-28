defmodule Core.Even do
  @moduledoc "Half of a runtime cycle with Core.Odd."
  def even?(0), do: true
  def even?(n), do: Core.Odd.odd?(n - 1)
end
