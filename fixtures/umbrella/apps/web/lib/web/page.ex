defmodule Web.Page do
  @moduledoc "Depends on Core.Account only transitively, through Web.AccountView."
  def show(account), do: "<h1>" <> Web.AccountView.render(account) <> "</h1>"
end
