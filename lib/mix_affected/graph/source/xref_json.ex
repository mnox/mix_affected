defmodule MixAffected.Graph.Source.XrefJson do
  @moduledoc """
  `MixAffected.Graph.Source` over `mix xref graph --format json` (Elixir >= 1.19).

  The JSON is a two-level map: source file to `%{sink file => kind}`, where
  kind is `"compile"`, `"export"` or `"runtime"`, and files without
  dependencies map to `{}`. Anything else is a `{:parse_error, detail}`.
  On Elixir 1.18 the format does not exist and `fetch/2` fails open with
  `{:xref_failed, status, output}`.
  """

  @behaviour MixAffected.Graph.Source

  alias MixAffected.Graph
  alias MixAffected.Graph.Source.Xref

  @kinds %{"compile" => :compile, "export" => :export, "runtime" => :runtime}

  @impl true
  def fetch(root, opts) do
    with {:ok, json} <- Xref.graph(root, "json", opts), do: parse(json)
  end

  @doc "Parses `mix xref graph --format json` output into adjacency."
  @spec parse(String.t()) :: {:ok, Graph.adjacency()} | {:error, Graph.error()}
  def parse(json) do
    case JSON.decode(json) do
      {:ok, graph} when is_map(graph) -> adjacency(graph)
      {:ok, other} -> {:error, {:parse_error, {:not_a_map, other}}}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp adjacency(graph) do
    Enum.reduce_while(graph, {:ok, %{}}, fn {from, deps}, {:ok, acc} ->
      case deps(deps) do
        {:ok, deps} -> {:cont, {:ok, Map.put(acc, from, deps)}}
        :error -> {:halt, {:error, {:parse_error, {from, deps}}}}
      end
    end)
  end

  defp deps(deps) when is_map(deps) do
    Enum.reduce_while(deps, {:ok, %{}}, fn {to, kind}, {:ok, acc} ->
      case Map.fetch(@kinds, kind) do
        {:ok, kind} -> {:cont, {:ok, Map.put(acc, to, kind)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp deps(_deps), do: :error
end
