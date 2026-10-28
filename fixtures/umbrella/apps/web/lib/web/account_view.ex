defmodule Web.AccountView do
  @moduledoc "Cross-app export (struct) and runtime dependency on Core.Account."
  def render(%Core.Account{} = account), do: Core.Account.display_name(account)
end
