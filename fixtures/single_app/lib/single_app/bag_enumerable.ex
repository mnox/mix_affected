defimpl Enumerable, for: SingleApp.Bag do
  # Reached only by protocol dispatch at runtime: nothing in xref depends on it.
  def count(%SingleApp.Bag{items: items}), do: {:ok, length(items)}
  def member?(%SingleApp.Bag{items: items}, value), do: {:ok, value in items}
  def slice(_bag), do: {:error, __MODULE__}
  def reduce(%SingleApp.Bag{items: items}, acc, fun), do: Enumerable.List.reduce(items, acc, fun)
end
