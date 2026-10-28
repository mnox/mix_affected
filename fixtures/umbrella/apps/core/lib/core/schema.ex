defmodule Core.Schema do
  @moduledoc "Compile-time target consumed across the app boundary via `use`."
  defmacro __using__(_opts) do
    quote do
      def schema?, do: true
    end
  end
end
