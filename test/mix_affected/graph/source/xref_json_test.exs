defmodule MixAffected.Graph.Source.XrefJsonTest do
  use MixAffected.SourceContract,
    source: MixAffected.Graph.Source.XrefJson,
    tags: [xref_json: true]
end
