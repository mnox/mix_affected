defmodule SingleApp.UserName do
  @moduledoc "Export dependency on SingleApp.User (struct pattern, no runtime call)."
  def name(%SingleApp.User{name: name}), do: name
end
