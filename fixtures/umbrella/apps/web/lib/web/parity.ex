defmodule Web.Parity do
  @moduledoc "Enters Core's Even/Odd cycle from the Web app."
  def parity(n), do: if(Core.Even.even?(n), do: :even, else: :odd)
end
