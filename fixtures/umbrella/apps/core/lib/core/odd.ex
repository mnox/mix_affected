defmodule Core.Odd do
  @moduledoc "Half of a runtime cycle with Core.Even."
  def odd?(0), do: false
  def odd?(n), do: Core.Even.even?(n - 1)
end
