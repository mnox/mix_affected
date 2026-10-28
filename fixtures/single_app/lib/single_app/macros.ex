defmodule SingleApp.Macros do
  @moduledoc "Compile-time target: consumed via `use` and via `require` + macro call."
  defmacro __using__(_opts) do
    quote do
      def greeting, do: "hello"
    end
  end

  defmacro double(expr) do
    quote do: unquote(expr) * 2
  end
end
