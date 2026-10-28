defmodule MixAffected.Graph do
  @moduledoc """
  File-level dependency graph of a compiled Mix project.

  Every path in a graph is relative to the project root (for an umbrella,
  that is the umbrella root, so paths look like `apps/web/lib/web/page.ex`).
  An edge `from -> to` of kind `t:kind/0` means `from` depends on `to`:

    * `:compile` - `from` needs `to` at compile time (`use`, `require` plus a
      macro call, `import`, module body calls)
    * `:export` - `from` depends on `to`'s exports, typically its struct
    * `:runtime` - `from` calls `to` at runtime

  When xref reports more than one kind for a pair, the strongest is kept
  (compile, then export, then runtime), as Mix itself does.

  ## Building

  `build/2` shells out to `mix xref graph` in the project directory with
  `MIX_ENV=test` (by default), so files the project compiles only in the test
  env, such as `test/support`, are part of the graph. See `build/2` for the
  options and `t:error/0` for every way it fails open.

  ## Selecting

  `dependents/2` returns the changed files plus every file that reaches one of
  them through any chain of edges of any kind. Cycles are fine.
  """

  alias MixAffected.Graph.Source

  @typedoc "A project-root-relative file path, e.g. `\"lib/my_app/user.ex\"`."
  @type path :: String.t()

  @typedoc "How `from` depends on `to` in an edge `from -> to`."
  @type kind :: :compile | :export | :runtime

  @typedoc "Outgoing edges per file: `%{from => %{to => kind}}`."
  @type adjacency :: %{optional(path) => %{optional(path) => kind}}

  @typedoc """
  Why a graph or a selection could not be produced. Every one of them means
  "run the full suite"; none is ever an empty selection.

    * `{:xref_failed, exit_status, output}` - `mix xref graph` exited non-zero
      (compile error, unsupported `--format`, missing deps, ...)
    * `:mix_not_found` - no `mix` executable on `PATH`
    * `{:output_unreadable, posix}` - xref succeeded but its output file
      could not be read
    * `{:parse_error, detail}` - xref output was not in the expected shape
    * `:empty_graph` - xref reported no source files at all
    * `{:unresolved_paths, paths}` - xref reported paths that are not files
      under the project root (or, for an umbrella, under any of its apps;
      usually an umbrella built without `:apps_paths`)
    * `{:ambiguous_paths, paths}` - umbrella children share these relative
      paths; xref merges same-named files and drops edges, so the graph
      cannot be trusted
    * `{:unknown_files, paths}` - `dependents/2` was asked about files that
      are not compiled sources in the graph (new, deleted, or non-source files)
  """
  @type error ::
          {:xref_failed, non_neg_integer(), String.t()}
          | :mix_not_found
          | {:output_unreadable, File.posix()}
          | {:parse_error, term()}
          | :empty_graph
          | {:unresolved_paths, [path]}
          | {:ambiguous_paths, [path]}
          | {:unknown_files, [path]}

  @typedoc """
    * `:root` - absolute project root every path is relative to
    * `:source` - the `MixAffected.Graph.Source` adapter that produced it
      (`nil` for `new/2`)
    * `:files` - every source file in the graph
    * `:edges` - outgoing edges, `%{from => %{to => kind}}`
    * `:dependents` - reverse edges, `%{to => MapSet of from}`
  """
  @type t :: %__MODULE__{
          root: Path.t(),
          source: module() | nil,
          files: MapSet.t(path),
          edges: adjacency(),
          dependents: %{optional(path) => MapSet.t(path)}
        }

  @enforce_keys [:root]
  defstruct root: nil, source: nil, files: MapSet.new(), edges: %{}, dependents: %{}

  @doc """
  Builds the graph of the compiled Mix project at `project_dir`.

  Options:

    * `:source` - the `MixAffected.Graph.Source` adapter; defaults to
      `MixAffected.Graph.Source.default(System.version())`
    * `:apps_paths` - for an umbrella, `%{app => relative_app_path}` as
      returned by `Mix.Project.apps_paths/0`. Defaults to
      `Mix.Project.apps_paths()` when `project_dir` is the current Mix
      project, otherwise `nil` (not an umbrella)
    * `:mix_env` - `MIX_ENV` for the xref run, default `"test"`
    * `:mix_executable` - path to `mix`, default the one on `PATH`

  The project is compiled first if it is stale (xref does that itself).
  """
  @spec build(Path.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def build(project_dir, opts \\ []) do
    root = Path.expand(project_dir)
    source = Keyword.get_lazy(opts, :source, fn -> Source.default(System.version()) end)
    apps_paths = Keyword.get_lazy(opts, :apps_paths, fn -> current_apps_paths(root) end)

    with {:ok, raw} <- source.fetch(root, opts),
         :ok <- non_empty(raw),
         {:ok, adjacency} <- resolve(raw, root, apps_paths) do
      {:ok, %{new(root, adjacency) | source: source}}
    end
  end

  @doc """
  Builds a graph from root-relative adjacency. Files that only appear as edge
  targets become files of the graph too.
  """
  @spec new(Path.t(), adjacency()) :: t()
  def new(root, adjacency) do
    files = raw_paths(adjacency)

    dependents =
      for {from, deps} <- adjacency, to <- Map.keys(deps), reduce: %{} do
        acc -> Map.update(acc, to, MapSet.new([from]), &MapSet.put(&1, from))
      end

    %__MODULE__{root: Path.expand(root), files: files, edges: adjacency, dependents: dependents}
  end

  @doc """
  Adds edges `{from, to, kind}` (keeping the stronger kind when `from -> to`
  exists), for dependencies only the caller knows about.
  """
  @spec put_edges(t(), [{path(), path(), kind()}]) :: t()
  def put_edges(%__MODULE__{} = graph, edges) do
    adjacency =
      Enum.reduce(edges, graph.edges, fn {from, to, kind}, acc ->
        Map.update(
          acc,
          from,
          %{to => kind},
          &Map.update(&1, to, kind, fn old -> stronger(old, kind) end)
        )
      end)

    %{new(graph.root, adjacency) | source: graph.source}
  end

  defp stronger(a, b), do: if(rank(a) <= rank(b), do: a, else: b)
  defp rank(:compile), do: 0
  defp rank(:export), do: 1
  defp rank(:runtime), do: 2

  @doc """
  Returns the changed files plus every file that transitively depends on any
  of them, over edges of every kind.

  `changed` may be root-relative or absolute paths under the root; the result
  is always root-relative. If any changed file is not a source in the graph the
  answer is `{:error, {:unknown_files, sorted_paths}}`: callers decide what
  non-source changes mean, the graph never guesses.
  """
  @spec dependents(t(), [Path.t()]) :: {:ok, MapSet.t(path)} | {:error, error()}
  def dependents(%__MODULE__{} = graph, changed) do
    changed = Enum.map(changed, &relative(graph.root, &1))

    case changed |> Enum.reject(&MapSet.member?(graph.files, &1)) |> Enum.uniq() |> Enum.sort() do
      [] -> {:ok, closure(graph.dependents, changed, MapSet.new(changed))}
      unknown -> {:error, {:unknown_files, unknown}}
    end
  end

  @doc "The kind of the edge `from -> to`, or `nil` when `from` does not depend on `to` directly."
  @spec edge(t(), path(), path()) :: kind() | nil
  def edge(%__MODULE__{edges: edges}, from, to), do: edges |> Map.get(from, %{}) |> Map.get(to)

  @doc "Every edge as `{from, to, kind}`, sorted."
  @spec edges(t()) :: [{path(), path(), kind()}]
  def edges(%__MODULE__{edges: edges}) do
    Enum.sort(for {from, deps} <- edges, {to, kind} <- deps, do: {from, to, kind})
  end

  @doc "Every source file in the graph."
  @spec files(t()) :: MapSet.t(path())
  def files(%__MODULE__{files: files}), do: files

  @doc "Whether `path` (root-relative or absolute under the root) is a source in the graph."
  @spec member?(t(), Path.t()) :: boolean()
  def member?(%__MODULE__{} = graph, path),
    do: MapSet.member?(graph.files, relative(graph.root, path))

  defp closure(_dependents, [], seen), do: seen

  defp closure(dependents, [file | rest], seen) do
    new = dependents |> Map.get(file, MapSet.new()) |> MapSet.difference(seen)
    closure(dependents, MapSet.to_list(new) ++ rest, MapSet.union(seen, new))
  end

  defp relative(root, path), do: path |> Path.expand(root) |> Path.relative_to(root)

  defp non_empty(raw) when map_size(raw) == 0, do: {:error, :empty_graph}
  defp non_empty(_raw), do: :ok

  defp current_apps_paths(root) do
    with project_file when is_binary(project_file) <- Mix.Project.project_file(),
         true <- Path.dirname(Path.expand(project_file)) == root do
      Mix.Project.apps_paths()
    else
      _ -> nil
    end
  end

  # xref paths are relative to the project, or for an umbrella root, to the
  # child app that owns them. Map each one to exactly one root-relative file.
  defp resolve(raw, root, apps_paths) do
    bases = bases(root, apps_paths)
    candidates = raw |> raw_paths() |> Map.new(&{&1, candidates(root, bases, &1)})

    with :ok <- refuse(:ambiguous_paths, candidates, &match?([_, _ | _], &1)),
         :ok <- refuse(:unresolved_paths, candidates, &(&1 == [])) do
      to = fn path -> hd(candidates[path]) end

      {:ok,
       Map.new(raw, fn {from, deps} ->
         {to.(from), Map.new(deps, fn {dep, kind} -> {to.(dep), kind} end)}
       end)}
    end
  end

  defp raw_paths(raw) do
    for {from, deps} <- raw, path <- [from | Map.keys(deps)], into: MapSet.new(), do: path
  end

  defp bases(_root, nil), do: [""]
  defp bases(root, apps_paths), do: apps_paths |> Map.values() |> Enum.map(&relative(root, &1))

  defp candidates(root, bases, path) do
    for base <- bases,
        candidate = if(base == "", do: path, else: Path.join(base, path)),
        File.regular?(Path.join(root, candidate)),
        do: candidate
  end

  defp refuse(reason, candidates, bad?) do
    case Enum.sort(for {path, found} <- candidates, bad?.(found), do: path) do
      [] -> :ok
      paths -> {:error, {reason, paths}}
    end
  end
end
