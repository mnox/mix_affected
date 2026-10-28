defmodule MixAffected.Run do
  @moduledoc """
  One selection, end to end: classify the change set, build the graph only if
  a source changed, build or read the test map only if anything is affected,
  add the map's protocol-impl edges to the graph, then select.

  Fail-open rules: a global invalidation or an unmapped file is a full run
  (exit status 0); a graph or test map that cannot be built is a full run with
  exit status 2 (`graph_unavailable:<detail>`, `test_map_unavailable:<detail>`).
  An affected protocol impl for a type outside the project is a full run
  (`unmapped_file:<impl file>`).

  An ignored file affects no source, but a test that reads it from the repo
  (its map `reads`) must still run: a change of only ignored files reads
  the map (building it if missing) to find those tests, and no graph.

  A selected test whose map entry is stale (its test file or a ref changed
  since the map was built) or missing is a full run with exit status 2
  (`test_map_unavailable:stale_entry:<test file>`): its references may be out
  of date. A map built for the run is never stale; this guards prebuilt maps.
  """

  alias MixAffected.Classifier
  alias MixAffected.Config
  alias MixAffected.Graph
  alias MixAffected.Graph.Source
  alias MixAffected.Graph.Source.Xref
  alias MixAffected.Result
  alias MixAffected.Selection
  alias MixAffected.TestMap
  alias MixAffected.TestMap.Ast
  alias MixAffected.TestMap.Builder

  @type opts :: [
          root: Path.t(),
          config: Config.t(),
          test_files: [Graph.path()],
          graph_source: String.t(),
          graph: (-> {:ok, Graph.t()} | {:error, Graph.error()}),
          test_map: (-> {:ok, TestMap.t()} | {:error, String.t()})
        ]

  @doc """
  Runs a selection over `changed`. Options (all required; `defaults/3` builds
  them for a real project):

    * `:root` - absolute project root
    * `:config` - `MixAffected.Config`
    * `:test_files` - every existing test file, root-relative
    * `:graph_source` - adapter name for the JSON `graph_source`
    * `:graph` - builds the graph, called at most once and only if a source changed
    * `:test_map` - reads or builds the test map, called at most once and
      only if anything is affected
  """
  @spec run([String.t()], opts()) :: Result.t()
  def run(changed, opts) do
    root = Keyword.fetch!(opts, :root)
    config = Keyword.fetch!(opts, :config)
    test_files = Keyword.fetch!(opts, :test_files)
    exists? = &File.exists?(Path.join(root, &1))
    classified = Classifier.classify(changed, config, root, exists?)

    result = %Result{
      changed_files: classified.changed,
      total_test_files: length(test_files),
      graph_source: Keyword.fetch!(opts, :graph_source)
    }

    with :ok <- not_full_run(classified),
         {:ok, graph} <- graph(classified, opts[:graph]),
         {:ok, _unmapped_checked} <- affected(classified, graph),
         {:ok, map} <- test_map(opts[:test_map]),
         :ok <- impls_known(classified.sources, map.impls, root),
         graph = with_impls(graph, map.impls),
         {:ok, affected} <- affected(classified, graph),
         :ok <- impls_vouched(affected, map.impls, graph) do
      stale = TestMap.stale(map, root)
      map = TestMap.mark_stale(map, stale)
      # A deleted test file still seeds: tests that used modules it defined
      # reference it in the map.
      seeds = classified.sources ++ classified.tests ++ classified.deleted_tests
      selection = Selection.select(graph, seeds, test_files, map, config, classified.ignored)

      case unvouched_entry(selection.tests, map, stale) do
        nil ->
          %{result | affected_files: affected, tests: selection.tests, explain: selection.explain}

        test ->
          Result.full_run(result, "test_map_unavailable:stale_entry:#{test}", 2)
      end
    else
      {:full_run, reason, status} -> Result.full_run(result, reason, status)
      :empty -> result
    end
  end

  @doc """
  Real `run/2` options for the project at `root`: the graph from `mix xref`
  (test env), the test map from `map_path`, built by a child
  `mix affected.map` when the file is missing.
  """
  @spec defaults(Path.t(), Config.t(), Path.t()) :: opts()
  def defaults(root, config, map_path) do
    source = Source.default(System.version())

    [
      root: root,
      config: config,
      test_files:
        Enum.map(
          Builder.test_files(root, config),
          &Path.relative_to(&1, root)
        ),
      graph_source: source_name(source),
      graph: fn -> Graph.build(root, source: source, mix_env: "test") end,
      test_map: fn -> ensure_map(root, map_path) end
    ]
  end

  @doc """
  Reads the map at `map_path`, building it there with a child
  `mix affected.map` when it is missing or in a format this version does not
  read (an older map lacks data selection relies on).
  """
  @spec ensure_map(Path.t(), Path.t()) :: {:ok, TestMap.t()} | {:error, String.t()}
  def ensure_map(root, map_path) do
    case TestMap.read(map_path) do
      {:ok, map} ->
        {:ok, map}

      {:error, "unknown_format"} ->
        IO.puts(:stderr, "mix_affected: rebuilding #{map_path}: unknown map format")
        build_map(root, map_path)

      {:error, "unreadable:enoent"} ->
        build_map(root, map_path)

      {:error, detail} ->
        {:error, detail}
    end
  end

  defp build_map(root, map_path) do
    case Xref.mix(root, ["affected.map", "--map", map_path], mix_env: "test") do
      {:ok, _log} ->
        TestMap.read(map_path)

      {:error, {:xref_failed, status, log}} ->
        IO.puts(:stderr, log)
        {:error, "affected.map_exit_#{status}"}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  @doc "The JSON `graph_source` name of an adapter."
  @spec source_name(module()) :: String.t()
  def source_name(Source.XrefJson), do: "xref_json"
  def source_name(Source.XrefDot), do: "xref_dot"
  def source_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp not_full_run(%Classifier{
         full_run: nil,
         sources: [],
         tests: [],
         deleted_tests: [],
         ignored: []
       }),
       do: :empty

  defp not_full_run(%Classifier{full_run: nil}), do: :ok
  defp not_full_run(%Classifier{full_run: reason}), do: {:full_run, reason, 0}

  defp graph(%Classifier{sources: []}, _build), do: {:ok, nil}

  defp graph(_classified, build) do
    case build.() do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        log_detail(reason)
        {:full_run, "graph_unavailable:#{describe(reason)}", 2}
    end
  end

  defp affected(classified, graph) do
    case Classifier.affected(classified, graph) do
      {:ok, affected} -> {:ok, affected}
      {:full_run, reason} -> {:full_run, reason, 0}
    end
  end

  defp test_map(build) do
    case build.() do
      {:ok, map} -> {:ok, map}
      {:error, detail} -> {:full_run, "test_map_unavailable:#{detail}", 2}
    end
  end

  # A selected test whose entry is stale or missing has references that may
  # be out of date: the load closure could omit a helper-defining test file
  # it now needs, failing a selection the full suite passes.
  defp unvouched_entry(selected, %TestMap{tests: entries}, stale) do
    stale = MapSet.new(stale)
    Enum.find(selected, &(MapSet.member?(stale, &1) or not Map.has_key?(entries, &1)))
  end

  # Protocol dispatch is invisible to xref: the type an impl is for depends
  # on the impl's file, so a changed impl affects the type's dependents.
  defp with_impls(nil, _impls), do: nil

  defp with_impls(graph, impls) do
    edges =
      for {impl_file, for_file} <- impls,
          is_binary(for_file) and for_file != impl_file,
          Graph.member?(graph, impl_file) and Graph.member?(graph, for_file),
          do: {for_file, impl_file, :runtime}

    Graph.put_edges(graph, edges)
  end

  # A changed source defining an impl the map has not recorded (added after
  # the map was built) has no known `for:` type to attach it to.
  defp impls_known(sources, impls, root) do
    known = MapSet.new(impls, &elem(&1, 0))

    case Enum.find(sources, &(not MapSet.member?(known, &1) and defines_impl?(root, &1))) do
      nil -> :ok
      file -> {:full_run, "unmapped_file:#{file}", 0}
    end
  end

  defp defines_impl?(root, file) do
    case File.read(Path.join(root, file)) do
      {:ok, source} -> Ast.defimpl?(source)
      {:error, _} -> true
    end
  end

  # An affected impl for a type outside the project (Integer, Any, a
  # dependency's struct), or for a file the graph no longer has, may be
  # dispatched to from anywhere.
  defp impls_vouched(_affected, _impls, nil), do: :ok

  defp impls_vouched(affected, impls, graph) do
    affected = MapSet.new(affected)

    unvouched =
      for {file, for_file} <- impls,
          MapSet.member?(affected, file),
          not (is_binary(for_file) and Graph.member?(graph, for_file)),
          do: file

    case unvouched do
      [] -> :ok
      [file | _] -> {:full_run, "unmapped_file:#{file}", 0}
    end
  end

  defp log_detail({:xref_failed, _status, log}), do: IO.puts(:stderr, log)
  defp log_detail(_reason), do: :ok

  @doc false
  @spec describe(term()) :: String.t()
  def describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  def describe({:xref_failed, status, _log}), do: "xref_failed:#{status}"

  def describe({tag, paths}) when is_atom(tag) and is_list(paths),
    do: "#{tag}:#{Enum.join(paths, ",")}"

  def describe({tag, detail}) when is_atom(tag) and is_atom(detail), do: "#{tag}:#{detail}"
  def describe({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  def describe(other), do: inspect(other)
end
