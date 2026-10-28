defmodule SingleApp.RequiresMacros do
  @moduledoc "Compile-time dependency on SingleApp.Macros via `require` and a macro call."
  require SingleApp.Macros

  def four, do: SingleApp.Macros.double(2)
end
