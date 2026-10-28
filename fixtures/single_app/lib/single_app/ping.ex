defmodule SingleApp.Ping do
  @moduledoc "Half of a runtime cycle with SingleApp.Pong."
  def ping(0), do: :done
  def ping(n), do: SingleApp.Pong.pong(n - 1)
end
