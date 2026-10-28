defmodule Mocks.Greeter do
  @moduledoc false
  def greet, do: "hello at #{Application.fetch_env!(:mocks, :clock).now()}"
end
