defmodule SingleApp.Transitive do
  @moduledoc "Depends on SingleApp.Leaf only through SingleApp.Direct."
  def value, do: SingleApp.Direct.value() + 1
end
