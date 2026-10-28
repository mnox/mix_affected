defmodule MixAffected.Graph.Source do
  @moduledoc """
  Behaviour for producing a project's raw file dependency graph.

  An adapter returns `t:MixAffected.Graph.adjacency/0` with paths exactly as
  the toolchain reports them (relative to the project, or to the owning child
  app at an umbrella root); `MixAffected.Graph.build/2` resolves them to
  root-relative paths. An adapter must never answer `{:ok, graph}` with a
  graph it could not fully read: any doubt is `{:error, reason}`.

  Adapters:

    * `MixAffected.Graph.Source.XrefJson` - `mix xref graph --format json`,
      Elixir >= 1.19
    * `MixAffected.Graph.Source.XrefDot` - `mix xref graph --format dot`, the
      path for Elixir 1.18 (dot edges carry `(compile)` / `(export)` labels,
      runtime edges are unlabelled)
  """

  alias MixAffected.Graph

  @doc """
  Reads the dependency graph of the compiled project at the absolute path
  `root`. Receives the options given to `MixAffected.Graph.build/2`.
  """
  @callback fetch(root :: Path.t(), opts :: keyword()) ::
              {:ok, Graph.adjacency()} | {:error, Graph.error()}

  @doc """
  The adapter for Elixir `version`: `XrefJson` from 1.19.0 on, `XrefDot`
  before (pre-releases of 1.19 included, since JSON output only shipped in
  the final release).
  """
  @spec default(String.t()) :: module()
  def default(version) do
    if Version.match?(version, ">= 1.19.0"),
      do: MixAffected.Graph.Source.XrefJson,
      else: MixAffected.Graph.Source.XrefDot
  end
end
