defmodule Mocks.Clock do
  @moduledoc "A behaviour production code resolves from config, so xref never links callers to it."
  @callback now() :: integer()
end
