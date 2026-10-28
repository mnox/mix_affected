defmodule SingleApp.Guarded.Policy do
  @moduledoc "Nothing references it; only SingleApp.SourceGuardTest scans its source."
  def allowed?(%{"origin" => origin}), do: origin in ["assigned", "refinement"]
end
