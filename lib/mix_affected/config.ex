defmodule MixAffected.Config do
  @moduledoc """
  The `affected:` settings of the consuming project, plus the test layout
  (`:test_paths`, `:test_pattern`) Mix itself uses to find test files.

      def project do
        [
          app: :my_app,
          affected: [
            # replaces the defaults when given
            global_invalidation: ["config/**", "mix.exs", "mix.lock", "test/test_helper.exs",
                                  "priv/repo/migrations/**"],
            # appended to global_invalidation
            extra_global_invalidation: [],
            # changed files that affect no test; default ["*.md", "docs/**/*.md"]
            # (other .md may be runtime data: it falls through as unmapped)
            ignore: ["*.md", "docs/**/*.md"],
            # source glob => test globs to run when a matching file is affected
            mappings: [{"lib/my_app/workers/**", ["test/my_app/workers/**"]}]
          ]
        ]
      end

  Every glob is matched by `MixAffected.Glob` against project-root-relative
  paths, and checked up front by `validate_glob/2`: a malformed glob, or a
  pattern naming a directory (one ending in `/`, or a glob-free pattern that
  is a directory under the project root; either would match no file), is an
  error rather than a rule that silently never fires.
  """

  alias MixAffected.Glob

  @default_global_invalidation [
    "config/**",
    "mix.exs",
    "mix.lock",
    "test/test_helper.exs",
    "priv/repo/migrations/**"
  ]

  @default_ignore ["*.md", "docs/**/*.md"]

  @keys [:global_invalidation, :extra_global_invalidation, :ignore, :mappings]

  @type mapping :: {String.t(), [String.t()]}

  @type t :: %__MODULE__{
          global_invalidation: [String.t()],
          ignore: [String.t()],
          mappings: [mapping()],
          test_paths: [String.t()],
          test_pattern: String.t()
        }

  defstruct global_invalidation: @default_global_invalidation,
            ignore: @default_ignore,
            mappings: [],
            test_paths: ["test"],
            test_pattern: "*_test.exs"

  @doc "The default `global_invalidation` globs."
  @spec default_global_invalidation() :: [String.t()]
  def default_global_invalidation, do: @default_global_invalidation

  @doc """
  Reads the config from a project keyword list (`Mix.Project.config/0`) of
  the project at `root`. Unknown `affected:` keys, malformed values and globs
  `validate_glob/2` rejects are errors, never ignored.
  """
  @spec from_project(keyword(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_project(project, root) do
    affected = Keyword.get(project, :affected, [])

    with :ok <- keyword(affected),
         :ok <- known_keys(affected),
         {:ok, global} <-
           globs(affected, :global_invalidation, @default_global_invalidation, root),
         {:ok, extra} <- globs(affected, :extra_global_invalidation, [], root),
         {:ok, ignore} <- globs(affected, :ignore, @default_ignore, root),
         {:ok, mappings} <- mappings(Keyword.get(affected, :mappings, []), root),
         test_paths = Keyword.get(project, :test_paths) || ["test"],
         test_pattern = Keyword.get(project, :test_pattern) || "*_test.exs",
         :ok <- test_layout(test_paths, test_pattern) do
      {:ok,
       %__MODULE__{
         global_invalidation: global ++ extra,
         ignore: ignore,
         mappings: mappings,
         test_paths: test_paths,
         test_pattern: test_pattern
       }}
    end
  end

  @doc """
  Checks a glob from the config or a test's `affected_by` against the project
  at `root`: it must compile (`MixAffected.Glob.compile/1`), must be in
  normal form and must not name a directory; any of those would leave a rule
  that matches no changed file. Changed paths are normalized, so a glob with
  a `.`, `..` or empty (`//`) segment never matches; the error gives the
  normal form, and a glob reaching outside the root is an error of its own.
  A glob ending in `/` (or `/.`, `/..`) names a directory whatever it holds;
  a pattern with no glob metacharacter names one when it is a directory
  under `root`. A leading `./` is allowed, as `MixAffected.Glob` ignores it.
  """
  @spec validate_glob(String.t(), Path.t()) :: :ok | {:error, String.t()}
  def validate_glob(glob, root) do
    path = strip_dot(glob)

    with {:ok, _regex} <- Glob.compile(glob),
         {:ok, normal} <- normalize(glob, path) do
      cond do
        directory?(path, normal, root) ->
          {:error,
           "glob #{inspect(glob)} names a directory, so it matches no file; " <>
             "write #{inspect(files_under(normal))} to match the files under it"}

        normal != path ->
          {:error,
           ~s(glob #{inspect(glob)} has a ".", ".." or empty segment, so it matches ) <>
             "no file (changed paths are normalized); write #{inspect(normal)}"}

        true ->
          :ok
      end
    end
  end

  defp directory?(path, normal, root) do
    String.ends_with?(path, "/") or Path.basename(path) in [".", ".."] or
      (Glob.literal?(path) and File.dir?(Path.join(root, normal)))
  end

  # Resolves `.`, `..` and empty segments without touching the filesystem;
  # an error when `..` climbs above the root. An absolute glob stays absolute.
  defp normalize(glob, path) do
    {lead, rest} = if String.starts_with?(path, "/"), do: {"/", path}, else: {"", path}

    rest
    |> String.split("/")
    |> Enum.reduce_while([], fn
      segment, acc when segment in ["", "."] -> {:cont, acc}
      "..", [] -> {:halt, :outside}
      "..", [_ | acc] -> {:cont, acc}
      segment, acc -> {:cont, [segment | acc]}
    end)
    |> case do
      :outside ->
        {:error, "glob #{inspect(glob)} reaches outside the project root, so it matches no file"}

      segments ->
        {:ok, lead <> (segments |> Enum.reverse() |> Enum.join("/"))}
    end
  end

  defp files_under(normal) do
    cond do
      normal == "" -> "**"
      String.ends_with?(normal, "**") -> normal
      true -> normal <> "/**"
    end
  end

  defp test_layout(paths, pattern) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case Glob.compile(Path.join([path, "**", pattern])) do
        {:ok, _regex} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "test_paths/test_pattern: #{reason}"}}
      end
    end)
  end

  @doc "Whether `path` is a test file: under a test path and matching the test pattern."
  @spec test_file?(t(), String.t()) :: boolean()
  def test_file?(%__MODULE__{test_paths: paths, test_pattern: pattern}, path) do
    Enum.any?(paths, &Glob.match?(Path.join([&1, "**", pattern]), path))
  end

  defp keyword(affected) do
    if Keyword.keyword?(affected),
      do: :ok,
      else: {:error, "affected: must be a keyword list, got #{inspect(affected)}"}
  end

  defp known_keys(affected) do
    case Keyword.keys(affected) -- @keys do
      [] -> :ok
      unknown -> {:error, "unknown affected: keys #{inspect(unknown)}; known: #{inspect(@keys)}"}
    end
  end

  defp globs(affected, key, default, root) do
    value = Keyword.get(affected, key, default)

    if string_list?(value),
      do: valid_globs(value, key, root),
      else: {:error, "affected: #{key} must be a list of glob strings, got #{inspect(value)}"}
  end

  defp valid_globs(globs, key, root) do
    Enum.reduce_while(globs, {:ok, globs}, fn glob, ok ->
      case validate_glob(glob, root) do
        :ok -> {:cont, ok}
        {:error, reason} -> {:halt, {:error, "affected: #{key}: #{reason}"}}
      end
    end)
  end

  defp mappings(value, root) do
    valid? =
      is_list(value) and
        Enum.all?(value, &match?({source, tests} when is_binary(source) and is_list(tests), &1)) and
        Enum.all?(value, fn {_source, tests} -> string_list?(tests) end)

    if valid?,
      do: valid_mappings(value, root),
      else:
        {:error,
         "affected: mappings must be a list of {source_glob, [test_glob]}, got #{inspect(value)}"}
  end

  defp valid_mappings(mappings, root) do
    globs = Enum.flat_map(mappings, fn {source, tests} -> [source | tests] end)

    with {:ok, _globs} <- valid_globs(globs, :mappings, root), do: {:ok, mappings}
  end

  defp strip_dot("./" <> rest), do: strip_dot(rest)
  defp strip_dot(path), do: path

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
end
