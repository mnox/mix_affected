defmodule MixAffected.Classifier do
  @moduledoc """
  Sorts a change set into what it means for test selection. Each changed
  file gets the first rule that applies:

    0. outside the project root - full run, `unmapped_file:<absolute path>`
    1. matches an `ignore` glob - dropped
    2. matches a `global_invalidation` glob - full run,
       `global_invalidation:<glob>:<file>`
    3. a test file (test paths + test pattern) - selected directly; a
       deleted one seeds the tests that used modules it defined
    4. an existing file - a source candidate; `affected/2` asks the graph to
       vouch for it (`Graph.dependents/2`)
    5. anything else (a deleted non-test file) - full run, `unmapped_file:<file>`

  A global invalidation outranks an unmapped file anywhere in the change set,
  so the reason names the strongest cause. `classify/3` never needs the graph,
  so an all-docs or tests-only change costs no xref run.
  """

  alias MixAffected.Config
  alias MixAffected.Glob
  alias MixAffected.Graph

  @type path :: Graph.path()
  @type reason :: String.t()

  @type t :: %__MODULE__{
          changed: [path],
          ignored: [path],
          tests: [path],
          deleted_tests: [path],
          sources: [path],
          full_run: reason() | nil
        }

  defstruct changed: [], ignored: [], tests: [], deleted_tests: [], sources: [], full_run: nil

  @doc """
  Classifies `changed` (paths relative to the absolute project `root`, or
  absolute, in any order, possibly with blanks or duplicates). Every path is
  canonicalized against `root` first (`lib/./a.ex` is `lib/a.ex`); one outside
  `root` is `unmapped_file:<absolute path>`. `exists?` answers whether a
  root-relative path exists in the working tree.
  """
  @spec classify([String.t()], Config.t(), Path.t(), (path -> boolean())) :: t()
  def classify(changed, %Config{} = config, root, exists?) do
    root = Path.expand(root)
    changed = normalize(changed, root)

    {result, global, unmapped} =
      Enum.reduce(changed, {%__MODULE__{changed: changed}, [], []}, fn file,
                                                                       {acc, global, unmapped} ->
        case rule(file, config, exists?) do
          :ignored -> {append(acc, :ignored, file), global, unmapped}
          {:global, glob} -> {acc, ["global_invalidation:#{glob}:#{file}" | global], unmapped}
          :test -> {append(acc, :tests, file), global, unmapped}
          :deleted_test -> {append(acc, :deleted_tests, file), global, unmapped}
          :source -> {append(acc, :sources, file), global, unmapped}
          :unmapped -> {acc, global, ["unmapped_file:#{file}" | unmapped]}
        end
      end)

    %{result | full_run: first(global) || first(unmapped)}
    |> Map.update!(:ignored, &Enum.reverse/1)
    |> Map.update!(:tests, &Enum.reverse/1)
    |> Map.update!(:deleted_tests, &Enum.reverse/1)
    |> Map.update!(:sources, &Enum.reverse/1)
  end

  @doc """
  The affected files of a classification without a full run: the reverse
  transitive closure of its sources in `graph` plus its changed tests,
  sorted. A source the graph does not compile (an external resource such as
  a template, or any non-source file) means `{:full_run, "unmapped_file:<file>"}`.
  `graph` may be `nil` when there are no sources.
  """
  @spec affected(t(), Graph.t() | nil) :: {:ok, [path]} | {:full_run, reason()}
  def affected(%__MODULE__{full_run: nil, sources: [], tests: tests}, _graph), do: {:ok, tests}

  def affected(%__MODULE__{full_run: nil, sources: sources, tests: tests}, %Graph{} = graph) do
    case Graph.dependents(graph, sources) do
      {:ok, closure} -> {:ok, closure |> MapSet.union(MapSet.new(tests)) |> Enum.sort()}
      {:error, {:unknown_files, [file | _]}} -> {:full_run, "unmapped_file:#{file}"}
    end
  end

  defp rule(file, config, exists?) do
    cond do
      Path.type(file) == :absolute -> :unmapped
      Glob.find(config.ignore, file) -> :ignored
      glob = Glob.find(config.global_invalidation, file) -> {:global, glob}
      Config.test_file?(config, file) -> if exists?.(file), do: :test, else: :deleted_test
      exists?.(file) -> :source
      true -> :unmapped
    end
  end

  # Root-relative canonical paths; a path outside the root stays absolute.
  defp normalize(changed, root) do
    changed
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&(&1 |> Path.expand(root) |> Path.relative_to(root)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp append(acc, key, file), do: Map.update!(acc, key, &[file | &1])

  defp first([]), do: nil
  defp first(reasons), do: reasons |> Enum.reverse() |> hd()
end
