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
  paths.
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
  Reads the config from a project keyword list (`Mix.Project.config/0`).
  Unknown `affected:` keys and malformed values are errors, never ignored.
  """
  @spec from_project(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_project(project) do
    affected = Keyword.get(project, :affected, [])

    with :ok <- keyword(affected),
         :ok <- known_keys(affected),
         {:ok, global} <- globs(affected, :global_invalidation, @default_global_invalidation),
         {:ok, extra} <- globs(affected, :extra_global_invalidation, []),
         {:ok, ignore} <- globs(affected, :ignore, @default_ignore),
         {:ok, mappings} <- mappings(Keyword.get(affected, :mappings, [])) do
      {:ok,
       %__MODULE__{
         global_invalidation: global ++ extra,
         ignore: ignore,
         mappings: mappings,
         test_paths: Keyword.get(project, :test_paths) || ["test"],
         test_pattern: Keyword.get(project, :test_pattern) || "*_test.exs"
       }}
    end
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

  defp globs(affected, key, default) do
    value = Keyword.get(affected, key, default)

    if string_list?(value),
      do: {:ok, value},
      else: {:error, "affected: #{key} must be a list of glob strings, got #{inspect(value)}"}
  end

  defp mappings(value) do
    valid? =
      is_list(value) and
        Enum.all?(value, &match?({source, tests} when is_binary(source) and is_list(tests), &1)) and
        Enum.all?(value, fn {_source, tests} -> string_list?(tests) end)

    if valid?,
      do: {:ok, value},
      else:
        {:error,
         "affected: mappings must be a list of {source_glob, [test_glob]}, got #{inspect(value)}"}
  end

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
end
