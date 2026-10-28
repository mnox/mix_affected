defmodule SingleApp.BagSize do
  @moduledoc "Reaches SingleApp.Bag's Enumerable impl only through Enum dispatch."
  def size(items), do: items |> SingleApp.Bag.new() |> Enum.count()
end
