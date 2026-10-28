defmodule SingleApp.Pong do
  @moduledoc "Half of a runtime cycle with SingleApp.Ping."
  def pong(0), do: :done
  def pong(n), do: SingleApp.Ping.ping(n - 1)
end
