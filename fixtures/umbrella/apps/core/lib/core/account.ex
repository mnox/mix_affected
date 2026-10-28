defmodule Core.Account do
  @moduledoc "Struct plus function consumed across the app boundary by Web."
  defstruct [:name]

  def display_name(%__MODULE__{name: name}), do: String.upcase(name)
end
