defmodule SingleApp.Rally do
  @moduledoc "Enters the Ping/Pong cycle from outside it."
  def start, do: SingleApp.Ping.ping(4)
end
