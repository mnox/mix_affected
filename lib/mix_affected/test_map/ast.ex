defmodule MixAffected.TestMap.Ast do
  @moduledoc """
  Reads a test file's source without compiling it: the modules it names
  (the fallback when requiring the file fails) and its `affected_by` globs.

  Alias resolution is file-wide, not lexical: `alias A.B` anywhere makes
  every `B...` reference resolve to `A.B...`, and the unaliased reading is
  kept too. Over-matching only selects more tests; it never drops one.
  """

  @doc """
  Every module the source names through an alias (`Foo.Bar`), resolving
  `alias`, `alias ..., as:` and `alias Foo.{A, B}`. `:error` if it does not parse.
  """
  @spec references(String.t()) :: {:ok, [module()]} | :error
  def references(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = aliases(ast)

        {_ast, modules} =
          Macro.prewalk(ast, MapSet.new(), fn
            {:__aliases__, _meta, [head | tail]} = node, acc when is_atom(head) ->
              {node, Enum.into(resolve(aliases, head, tail), acc)}

            node, acc ->
              {node, acc}
          end)

        {:ok, Enum.sort(modules)}

      {:error, _} ->
        :error
    end
  end

  @doc """
  The globs of every literal `@moduletag affected_by: ["glob", ...]` (also
  among other tags in the same keyword list) and `@affected_by ["glob", ...]`
  in the source; `[]` if none or unparseable.
  """
  @spec affected_by(String.t()) :: [String.t()]
  def affected_by(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_ast, globs} = Macro.prewalk(ast, [], &{&1, &2 ++ affected_by_globs(&1)})
        Enum.uniq(globs)

      {:error, _} ->
        []
    end
  end

  defp affected_by_globs({:@, _, [{:affected_by, _, [list]}]}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp affected_by_globs({:@, _, [{:moduletag, _, [tags]}]}) when is_list(tags) do
    for {:affected_by, list} when is_list(list) <- tags, glob <- list, is_binary(glob), do: glob
  end

  defp affected_by_globs(_node), do: []

  # Calls that read or list files, by module; their arguments are where a
  # test names what it reads.
  @readers %{
    File =>
      ~w(read read! stream! ls ls! exists? regular? dir? open open! stat stat! lstat lstat!)a,
    Path => [:wildcard],
    Code => [:eval_file, :require_file, :compile_file],
    EEx => [:eval_file, :compile_file],
    YamlElixir => [:read_from_file, :read_from_file!, :read_all_from_file, :read_all_from_file!]
  }
  @erlang_readers %{file: [:read_file, :consult, :list_dir, :read_file_info, :open]}
  # A stand-in absolute root for resolving `__DIR__`-relative paths.
  @root "/__mix_affected_root__"

  @doc """
  The root-relative globs of the files a test reads from the repo itself
  (a source-scanning guard reading `lib/**`, a doc test reading
  `guides/*.md`, a Dockerfile test), found without compiling it: `[]` when
  the source calls no file-reading or -listing function (`File.read!/1`,
  `Path.wildcard/1`, ... or `@external_resource`), else a glob per path
  literal anywhere in the file whose first segment is one of `top_level`
  (the entries of the project root). A literal names a file or a directory,
  so `"lib/app"` reads `lib/app` and `lib/app/**`; literal globs are kept.

  `Path.join/1,2` of leading literals reads the joined path, `Path.expand/2`
  and `Path.join/2` from `__DIR__` resolve against `test_file`'s directory,
  `:code.priv_dir/1` is `priv`, `~w` words and the literal parts of an
  interpolation (`"\#{File.cwd!()}/guides/x.md"`) count as literals, other
  sigils (regexes) do not.

  `["**"]` (reads everything) when the reads cannot be pinned to the repo:
  the source does not parse, it reads but no literal names a repo path, a
  reading call's literal argument is not anchored at the root (`"."`,
  `"**/*.ex"`, a relative `"fixtures/x.json"`), it lists the working
  directory (`File.ls!/0`, `File.cwd!()`), or a `__DIR__` path leaves the root.
  """
  @spec reads(String.t(), String.t(), [String.t()]) :: [String.t()]
  def reads(source, test_file, top_level) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        ctx = %{dir: Path.dirname(test_file), top: MapSet.new(top_level)}
        acc = %{reader?: false, everything?: false, paths: []}
        {_ast, acc} = Macro.prewalk(ast, acc, &read_node(&1, &2, ctx))
        read_globs(acc, ctx)

      {:error, _} ->
        ["**"]
    end
  end

  defp read_globs(%{reader?: false}, _ctx), do: []
  defp read_globs(%{everything?: true}, _ctx), do: ["**"]

  defp read_globs(%{paths: paths}, ctx) do
    case paths |> Enum.flat_map(&globs(&1, ctx)) |> Enum.uniq() |> Enum.sort() do
      [] -> ["**"]
      globs -> globs
    end
  end

  # {node to keep walking, acc}. A node whose literals are consumed here is
  # replaced by its non-literal parts, so its literals are not read twice.
  defp read_node({{:., _, [{:__aliases__, _, [:Path]}, :join]}, _, args} = node, acc, ctx) do
    parts =
      case args do
        [list] when is_list(list) -> list
        args -> args
      end

    case joined(parts) do
      {:ok, path, rest} -> {{:__block__, [], rest}, add_path(acc, path, ctx)}
      :error -> {node, acc}
    end
  end

  defp read_node(
         {{:., _, [{:__aliases__, _, [:Path]}, :expand]}, _, [path, {:__DIR__, _, _}]},
         acc,
         ctx
       )
       when is_binary(path),
       do: {:ok, add_path(acc, {:dir, path}, ctx)}

  defp read_node({{:., _, [:code, :priv_dir]}, _, _}, acc, ctx),
    do: {:ok, add_path(acc, "priv", ctx)}

  defp read_node({{:., _, [{:__aliases__, _, aliases}, fun]}, _, args} = node, acc, ctx)
       when is_list(args) do
    if atoms?(aliases) and fun in Map.get(@readers, Module.concat(aliases), []),
      do: {node, reader(acc, fun, args, ctx)},
      else: {node, acc}
  end

  defp read_node({{:., _, [erlang, fun]}, _, args} = node, acc, ctx)
       when is_atom(erlang) and is_list(args) do
    if fun in Map.get(@erlang_readers, erlang, []),
      do: {node, reader(acc, fun, args, ctx)},
      else: {node, acc}
  end

  defp read_node({:@, _, [{:external_resource, _, [_]}]} = node, acc, _ctx),
    do: {node, %{acc | reader?: true}}

  defp read_node({:<<>>, _, parts}, acc, ctx) do
    {fragments, exprs} = interpolation(parts)
    {{:__block__, [], exprs}, Enum.reduce(fragments, acc, &add_path(&2, &1, ctx))}
  end

  defp read_node({sigil, _, [{:<<>>, _, parts}, _mods]}, acc, ctx)
       when sigil in [:sigil_w, :sigil_W] do
    words = for part <- parts, is_binary(part), word <- String.split(part), do: word
    {:ok, Enum.reduce(words, acc, &add_path(&2, &1, ctx))}
  end

  # A string sigil is a string; any other (a regex, a charlist) names no path.
  defp read_node({sigil, _, [{:<<>>, _, _} = string, _mods]} = node, acc, _ctx)
       when is_atom(sigil) do
    cond do
      sigil in [:sigil_s, :sigil_S] -> {string, acc}
      String.starts_with?(Atom.to_string(sigil), "sigil_") -> {:ok, acc}
      true -> {node, acc}
    end
  end

  defp read_node(literal, acc, ctx) when is_binary(literal),
    do: {literal, add_path(acc, literal, ctx)}

  defp read_node(node, acc, _ctx), do: {node, acc}

  # A reading call. A direct literal argument that is not a repo path, or
  # listing the working directory, may read anything.
  defp reader(acc, fun, args, ctx) do
    acc = %{acc | reader?: true}

    case args do
      [] when fun in [:ls, :ls!] -> %{acc | everything?: true}
      ["/" <> _ | _] -> acc
      [path | _] when is_binary(path) -> if anchored?(path, ctx), do: acc, else: everything(acc)
      [{{:., _, [{:__aliases__, _, [:File]}, :cwd!]}, _, []} | _] -> everything(acc)
      _ -> acc
    end
  end

  defp everything(acc), do: %{acc | everything?: true}

  # {:ok, path, non-literal rest} for Path.join parts that start with a base
  # (`__DIR__`, `:code.priv_dir/1`) or a literal.
  defp joined(parts) do
    {base, parts} =
      case parts do
        [{:__DIR__, _, _} | rest] -> {:dir, rest}
        [{{:., _, [:code, :priv_dir]}, _, _} | rest] -> {"priv", rest}
        parts -> {nil, parts}
      end

    {literals, rest} = Enum.split_while(parts, &is_binary/1)

    case {base, literals} do
      {nil, []} -> :error
      {nil, literals} -> {:ok, Path.join(literals), rest}
      {:dir, []} -> {:ok, {:dir, "."}, rest}
      {:dir, literals} -> {:ok, {:dir, Path.join(literals)}, rest}
      {root, literals} -> {:ok, Path.join([root | literals]), rest}
    end
  end

  # A `{:dir, path}` is relative to the test file's directory: resolved to
  # the root, the root itself is only a base, leaving it may read anything.
  defp add_path(acc, {:dir, path}, ctx) do
    expanded = Path.expand(Path.join(ctx.dir, path), @root)

    cond do
      expanded == @root ->
        acc

      String.starts_with?(expanded, @root <> "/") ->
        add_path(acc, Path.relative_to(expanded, @root), ctx)

      true ->
        %{acc | paths: ["**" | acc.paths]}
    end
  end

  defp add_path(acc, path, _ctx) when is_binary(path), do: %{acc | paths: [path | acc.paths]}

  # {literal fragments, interpolated exprs}. A fragment after an
  # interpolation is read as root-relative (`"\#{root}/lib/x"`).
  defp interpolation(parts) do
    {fragments, exprs, _after?} =
      Enum.reduce(parts, {[], [], false}, fn
        part, {fragments, exprs, after?} when is_binary(part) ->
          fragment = if after?, do: String.trim_leading(part, "/"), else: part
          {[fragment | fragments], exprs, false}

        {:"::", _, [expr, _type]}, {fragments, exprs, _after?} ->
          {fragments, [expr | exprs], true}

        expr, {fragments, exprs, _after?} ->
          {fragments, [expr | exprs], true}
      end)

    {fragments, exprs}
  end

  defp anchored?(path, ctx) do
    [first | _] = path |> strip_dot() |> String.split("/")
    not glob?(first) and MapSet.member?(ctx.top, first)
  end

  # A literal names a file or a directory; a literal glob is kept as is.
  defp globs("**", _ctx), do: ["**"]

  defp globs(path, ctx) do
    path = path |> strip_dot() |> String.trim_trailing("/")

    cond do
      not anchored?(path, ctx) -> []
      glob?(path) -> [path]
      true -> [path, path <> "/**"]
    end
  end

  defp strip_dot("./" <> rest), do: strip_dot(rest)
  defp strip_dot(path), do: path

  defp glob?(path), do: String.contains?(path, ["*", "?", "{", "["])

  @doc "Whether the source defines a protocol impl (`defimpl`); `true` if it does not parse."
  @spec defimpl?(String.t()) :: boolean()
  def defimpl?(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_ast, found?} =
          Macro.prewalk(ast, false, fn
            {:defimpl, _, [_ | _]} = node, _acc -> {node, true}
            node, acc -> {node, acc}
          end)

        found?

      {:error, _} ->
        true
    end
  end

  defp resolve(aliases, head, tail) do
    raw = Module.concat([head | tail])
    [raw | for(base <- Map.get(aliases, head, []), do: Module.concat([base | tail]))]
  end

  # %{short_name => [full module]} for every alias form in the file.
  defp aliases(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [target | opts]} = node, acc ->
          {node, Enum.reduce(alias_pairs(target, opts), acc, &put_alias/2)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp alias_pairs({:__aliases__, _, parts}, [[as: {:__aliases__, _, [as]}]]) when is_atom(as),
    do: if(atoms?(parts), do: [{as, Module.concat(parts)}], else: [])

  defp alias_pairs({:__aliases__, _, parts}, _opts),
    do: if(atoms?(parts), do: [{List.last(parts), Module.concat(parts)}], else: [])

  defp alias_pairs({{:., _, [{:__aliases__, _, base}, :{}]}, _, children}, _opts) do
    for {:__aliases__, _, parts} <- children,
        atoms?(base ++ parts),
        do: {List.last(parts), Module.concat(base ++ parts)}
  end

  defp alias_pairs(_target, _opts), do: []

  defp put_alias({short, full}, acc), do: Map.update(acc, short, [full], &Enum.uniq([full | &1]))

  defp atoms?(parts), do: Enum.all?(parts, &is_atom/1)
end
