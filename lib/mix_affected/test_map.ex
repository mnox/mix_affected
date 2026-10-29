defmodule MixAffected.TestMap do
  @moduledoc """
  Which source files each test file references, built by `mix affected.map`
  (see `MixAffected.TestMap.Builder`) and stored as an ETF file, by default at
  `_build/test/mix_affected/test_map.etf`.

  Each test file has an entry:

    * `:mode` - how its references were found: `:tracer` (compiler tracer
      while requiring the file), `:ast` (the file failed to require; module
      references read from its AST, which misses what `use` injects, so the
      test runs whenever anything is affected), or `:always` (it does not
      parse either, or an `affected_by` glob was rejected: same)
    * `:refs` - root-relative source files of every module it references,
      including other test files that define modules it uses
    * `:hashes` - `%{path => hash/1}` of the test file and of every file in
      `:refs`, as they were when the map was built. An entry whose files
      changed since is `stale/2`: its references may be out of date (a map
      prebuilt on another commit, a test edited after the local map was
      built), so selecting it is a full run (see `MixAffected.Run`).
    * `:unresolved` - names of traced modules no file defines and none can
      be loaded (typically defined by a file deleted or edited before the map
      was built); any seed selects every test with any
    * `:affected_by` - its literal `@moduletag affected_by: [globs]` and
      `@affected_by [globs]`, minus any `MixAffected.Config.validate_glob/2`
      rejects (which make the entry `:always`)
    * `:reads` - globs of the repo files it reads itself (`File.read!/1`,
      `Path.wildcard/1`, ...: a guard scanning `lib/**`, a doc test), `["**"]`
      when they cannot be pinned down, `[]` when it reads none
      (`MixAffected.TestMap.Ast.reads/3`)

  `:impls` lists the project's protocol implementations as
  `{impl_file, for_file}`: protocol dispatch is a runtime lookup no xref edge
  records, so selection treats the `for:` type's file as depending on the
  impl file (`for_file` equals `impl_file` for an impl in its type's own file or
  from `@derive`). `for_file` is `nil` when the type is not defined in the project
  (`Integer`, `Any`, a dependency's struct): then nothing in the project can
  vouch for who dispatches to it.
  """

  @version 3

  @type path :: MixAffected.Graph.path()
  @type mode :: :tracer | :ast | :always
  @type entry :: %{
          mode: mode(),
          refs: [path],
          affected_by: [String.t()],
          hashes: %{optional(path) => binary()},
          unresolved: [String.t()],
          reads: [String.t()]
        }
  @type impl :: {impl_file :: path, for_file :: path | nil}
  @type t :: %__MODULE__{tests: %{optional(path) => entry()}, impls: [impl()]}

  defstruct tests: %{}, impls: []

  @doc "A map from `%{test_file => entry}` and the project's protocol impls."
  @spec new(%{optional(path) => entry()}, [impl()]) :: t()
  def new(tests, impls \\ []), do: %__MODULE__{tests: tests, impls: impls}

  @doc "The default map path under a build path such as `_build/test`."
  @spec default_path(Path.t()) :: Path.t()
  def default_path(build_path), do: Path.join([build_path, "mix_affected", "test_map.etf"])

  @doc "Writes `map` to `path`, creating its directory."
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{tests: tests, impls: impls}, path) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      :erlang.term_to_binary({__MODULE__, @version, %{tests: tests, impls: impls}})
    )
  end

  @doc "Reads a map written by `write!/2` by the same map format version."
  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, {__MODULE__, @version, %{tests: tests, impls: impls}}}
         when is_map(tests) and is_list(impls) <- decode(binary),
         true <- Enum.all?(Map.values(tests), &entry?/1) do
      {:ok, new(tests, impls)}
    else
      {:error, posix} when is_atom(posix) -> {:error, "unreadable:#{posix}"}
      _other -> {:error, "unknown_format"}
    end
  end

  @doc "The content hash the map stores for a file's `content`."
  @spec hash(binary()) :: binary()
  def hash(content), do: :erlang.md5(content)

  @doc """
  The test files, sorted, whose entry's recorded `:hashes` no longer match
  the files under `root` (changed or missing): their references may be out
  of date.
  """
  @spec stale(t(), Path.t()) :: [path]
  def stale(%__MODULE__{tests: tests}, root) do
    paths =
      for {_test, %{hashes: hashes}} <- tests, path <- Map.keys(hashes), uniq: true, do: path

    current = Map.new(paths, &{&1, current_hash(Path.join(root, &1))})

    for {test, %{hashes: hashes}} <- tests,
        not Enum.all?(hashes, fn {path, hash} -> current[path] == hash end),
        do: test
  end

  @doc """
  Marks the entries of the `stale` test files `:always`, so selection
  selects them whenever anything is affected instead of trusting their
  references.
  """
  @spec mark_stale(t(), [path]) :: t()
  def mark_stale(%__MODULE__{tests: tests} = map, stale) do
    tests =
      Enum.reduce(stale, tests, fn test, acc ->
        Map.update!(acc, test, &%{&1 | mode: :always})
      end)

    %{map | tests: tests}
  end

  defp current_hash(file) do
    case File.read(file) do
      {:ok, content} -> hash(content)
      {:error, _} -> nil
    end
  end

  # The entry shape selection relies on. Matching it here also keeps every
  # entry atom in this module, so `:safe` decoding never depends on which
  # other modules the reading VM happened to load.
  defp entry?(%{mode: mode, refs: _, affected_by: _, hashes: _, unresolved: _, reads: _}),
    do: mode in [:tracer, :ast, :always]

  defp entry?(_entry), do: false

  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
