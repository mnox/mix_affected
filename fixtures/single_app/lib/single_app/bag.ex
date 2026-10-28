defmodule SingleApp.Bag do
  @moduledoc "Struct whose Enumerable impl lives in its own file (bag_enumerable.ex)."
  defstruct items: []

  def new(items), do: %__MODULE__{items: items}
end
