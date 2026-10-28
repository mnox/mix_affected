defmodule MixAffected.TestMap.Builder do
  @moduledoc """
  Builds a `MixAffected.TestMap` inside the consuming project's VM, the way
  `mix test` loads tests but without running any: the project must already
  be compiled (and its apps started, as `mix test` does) by the caller.

    1. `ExUnit.start(autorun: false)`, then each test path's
       `test_helper.exs` is required (a failing helper is reported and
       skipped: tracing only needs the test modules to compile)
    2. every test file is required in parallel with
       `MixAffected.TestMap.Tracer` registered as a compiler tracer
    3. files that did not finish (an error, or the parallel compiler stopping
       on someone else's error) are retried one at a time
    4. a file that still fails gets its references from its AST
       (`MixAffected.TestMap.Ast`, mode `:ast`); one that does not parse
       either is `:always`
    5. every file's `:reads` (repo files it reads itself) come from its AST,
       anchored at the entries of the root (`MixAffected.TestMap.Ast.reads/3`)

  Referenced modules are mapped to their source file: the test file that
  defined them, else `module_info(:compile)[:source]`. Sources outside the
  root, or under an `:exclude` dir (deps, `_build`), are dropped.

  A referenced Mox mock (a loaded module exporting `__mock_for__/0`) also
  references the behaviours it mocks; mocks are defined by `test_helper.exs`,
  which is required before the test files are traced.

  Protocol impls among the project's `:modules` are recorded with the file
  of the type they are for (`nil` when that type is not a project module).
  """

  alias MixAffected.Config
  alias MixAffected.TestMap
  alias MixAffected.TestMap.Ast
  alias MixAffected.TestMap.Tracer

  @type stats :: %{
          tracer: non_neg_integer(),
          ast: non_neg_integer(),
          always: non_neg_integer(),
          helper_errors: [String.t()]
        }

  @doc """
  Options: `:exclude` - absolute dirs whose sources are never refs;
  `:modules` - the project's compiled modules, searched for protocol impls
  (`TestMap` `:impls`). `root` is the absolute project root.
  """
  @spec build(Path.t(), Config.t(), keyword()) :: {TestMap.t(), stats()}
  def build(root, %Config{} = config, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])
    files = test_files(root, config)
    helper_errors = start_ex_unit(root, config)

    table = :ets.new(Tracer.table(), [:named_table, :public, :bag])

    try do
      failed = trace(files)
      defined = for {{:def, module}, file} <- :ets.tab2list(table), into: %{}, do: {module, file}
      resolve = &source(&1, defined, root, exclude)
      missing? = &(not Map.has_key?(defined, &1) and not Code.ensure_loaded?(&1))
      top_level = File.ls!(root)

      tests =
        Map.new(files, fn file ->
          traced = for {_key, module} <- :ets.lookup(table, {:ref, file}), do: module

          {relative(root, file),
           entry(file, traced, MapSet.member?(failed, file), {resolve, missing?, top_level}, root)}
        end)

      impls = impls(Keyword.get(opts, :modules, []), &source(&1, %{}, root, exclude))
      {TestMap.new(tests, impls), Map.put(count(tests), :helper_errors, helper_errors)}
    after
      :ets.delete(table)
    end
  end

  @doc "Every test file of the project, absolute, sorted (as `mix test` finds them)."
  @spec test_files(Path.t(), Config.t()) :: [Path.t()]
  def test_files(root, %Config{test_paths: paths, test_pattern: pattern}) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", pattern])))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp start_ex_unit(root, config) do
    Application.put_env(:ex_unit, :autorun, false)
    ExUnit.start(autorun: false)

    for path <- config.test_paths,
        helper = Path.join([root, path, "test_helper.exs"]),
        File.exists?(helper),
        error = require_helper(helper),
        do: error
  end

  defp require_helper(helper) do
    Code.require_file(helper)
    nil
  catch
    kind, reason -> "#{relative(File.cwd!(), helper)}: #{Exception.format_banner(kind, reason)}"
  end

  # Requires every file with the tracer on; returns the files that never compiled.
  defp trace(files) do
    previous = Code.get_compiler_option(:tracers)
    Code.put_compiler_option(:tracers, [Tracer | previous])
    done = :ets.new(:mix_affected_done, [:public, :set])

    try do
      Kernel.ParallelCompiler.require(files,
        each_file: fn file -> :ets.insert(done, {file}) end,
        return_diagnostics: true
      )

      # Retry what did not finish, one file at a time; keep what still fails.
      files
      |> Enum.reject(&(:ets.member(done, &1) or compile_alone(&1)))
      |> MapSet.new()
    after
      Code.put_compiler_option(:tracers, previous)
      :ets.delete(done)
    end
  end

  defp compile_alone(file) do
    Code.compile_file(file)
    true
  catch
    _kind, _reason -> false
  end

  defp entry(file, traced, failed?, {resolve, missing?, top_level}, root) do
    source = File.read!(file)
    self = relative(root, file)
    affected_by = Ast.affected_by(source)

    {mode, refs} =
      case {failed?, failed? && Ast.references(source)} do
        {false, _} -> {:tracer, refs(traced, resolve, self)}
        {true, {:ok, named}} -> {:ast, refs(traced ++ named, resolve, self)}
        {true, :error} -> {:always, []}
      end

    hashes =
      Map.new(refs, &{&1, TestMap.hash(File.read!(Path.join(root, &1)))})
      |> Map.put(self, TestMap.hash(source))

    # Names, not atoms: the selecting VM reads the map with `:safe` and has
    # never seen these atoms.
    unresolved =
      traced |> Enum.uniq() |> Enum.filter(missing?) |> Enum.map(&inspect/1) |> Enum.sort()

    %{
      mode: mode,
      refs: refs,
      affected_by: affected_by,
      hashes: hashes,
      unresolved: unresolved,
      reads: Ast.reads(source, self, top_level)
    }
  end

  defp refs(modules, resolve, self) do
    modules
    |> Enum.uniq()
    |> Enum.flat_map(&[&1 | mocked_behaviours(&1)])
    |> Enum.flat_map(&List.wrap(resolve.(&1)))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == self))
    |> Enum.sort()
  end

  # A Mox mock (`Mox.defmock/2`, usually in test_helper.exs) has no project
  # source, and production code reaches the real implementation through
  # config, so the behaviours it mocks are the only link to the test.
  defp mocked_behaviours(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__mock_for__, 0),
      do: List.wrap(module.__mock_for__()),
      else: []
  end

  defp source(module, defined, root, exclude) do
    with file when is_binary(file) <- Map.get(defined, module) || compiled_source(module),
         file = Path.expand(file),
         true <- under?(file, root),
         false <- Enum.any?(exclude, &under?(file, &1)) do
      relative(root, file)
    else
      _ -> nil
    end
  end

  defp compiled_source(module) do
    with {:module, _} <- Code.ensure_loaded(module),
         source when is_list(source) <- module.module_info(:compile)[:source] do
      List.to_string(source)
    else
      _ -> nil
    end
  end

  # {impl_file, for_file | nil} per project impl (for_file == impl_file when
  # the impl sits in its type's file or comes from @derive).
  defp impls(modules, resolve) do
    modules
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__impl__, 1)))
    |> Enum.map(&{resolve.(&1), resolve.(&1.__impl__(:for))})
    |> Enum.filter(fn {impl_file, _for_file} -> is_binary(impl_file) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp count(tests) do
    Enum.reduce(tests, %{tracer: 0, ast: 0, always: 0}, fn {_file, %{mode: mode}}, acc ->
      Map.update!(acc, mode, &(&1 + 1))
    end)
  end

  defp under?(file, dir), do: String.starts_with?(file, Path.expand(dir) <> "/")
  defp relative(root, file), do: Path.relative_to(file, root)
end
