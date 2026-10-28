defmodule MixAffected.Graph.Source.XrefDot do
  @moduledoc """
  `MixAffected.Graph.Source` over `mix xref graph --format dot`, the adapter
  for Elixir 1.18 (which has no JSON format).

  The dot output lists every source file as a node line and every dependency
  as an edge line; compile and export edges are labelled, runtime edges are
  not:

      digraph "xref graph" {
        "lib/a.ex"
        "lib/a.ex" -> "lib/b.ex"
        "lib/b.ex" -> "lib/a.ex" [label="(compile)"]
        "lib/c.ex" -> "lib/a.ex" [label="(export)"]
      }

  Any line outside that shape is a `{:parse_error, line}`.
  """

  @behaviour MixAffected.Graph.Source

  alias MixAffected.Graph
  alias MixAffected.Graph.Source.Xref

  @node ~r/\A"([^"]+)"\z/
  @edge ~r/\A"([^"]+)" -> "([^"]+)"(?: \[label="\(([a-z]+)\)"\])?\z/
  @labels %{"compile" => :compile, "export" => :export}

  @impl true
  def fetch(root, opts) do
    with {:ok, dot} <- Xref.graph(root, "dot", opts), do: parse(dot)
  end

  @doc "Parses `mix xref graph --format dot` output into adjacency."
  @spec parse(String.t()) :: {:ok, Graph.adjacency()} | {:error, Graph.error()}
  def parse(dot) do
    dot
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in [~s(digraph "xref graph" {), "}", ""]))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:node, file} -> {:cont, {:ok, Map.put_new(acc, file, %{})}}
        {:edge, from, to, kind} -> {:cont, {:ok, put_edge(acc, from, to, kind)}}
        :error -> {:halt, {:error, {:parse_error, line}}}
      end
    end)
  end

  defp parse_line(line) do
    cond do
      match = Regex.run(@node, line, capture: :all_but_first) ->
        {:node, hd(match)}

      match = Regex.run(@edge, line, capture: :all_but_first) ->
        edge(match)

      true ->
        :error
    end
  end

  defp edge([from, to]), do: {:edge, from, to, :runtime}

  defp edge([from, to, label]) do
    case Map.fetch(@labels, label) do
      {:ok, kind} -> {:edge, from, to, kind}
      :error -> :error
    end
  end

  defp put_edge(acc, from, to, kind),
    do: Map.update(acc, from, %{to => kind}, &Map.put(&1, to, kind))
end
