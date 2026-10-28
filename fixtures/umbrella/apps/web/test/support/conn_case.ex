defmodule Web.ConnCase do
  @moduledoc "Test-support module compiled only in the test env."
  def page_for(name), do: Web.Page.show(%Core.Account{name: name})
end
