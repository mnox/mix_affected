defmodule MixAffected.Selection do
  @moduledoc """
  Picks the test files to run from the seeds of a change (changed sources the
  graph knows, plus changed test files) and the test map.

  It walks one graph whose edges point from a file to whatever it may change:

    * source -> source: `MixAffected.Graph` reverse edges (any kind)
    * file -> test: the test references a module defined in the file (the
      file may itself be a test file that defines helper modules)
    * file -> test: one of the test's `affected_by` globs (tag or attribute) matches the file
    * file -> test: a config mapping's source glob matches the file and one of
      its test globs matches the test
    * any seed -> test: the test references a module that resolves to
      nothing (the changed or deleted file, source or test, may have defined it)
    * seed -> test: one of the test's `reads` globs (files it reads from the
      repo, such as a guard scanning `lib/**`) matches the seed. Only a seed's
      content changed, so a file the walk merely reaches does not count.

  `read_only` files (changed files the config ignores) select only the tests
  whose `reads` match them, and tests the map does not know (which may read
  anything); they seed nothing else.

  Every test file it reaches is selected, and so is every test file a
  selected test needs loaded: one defining a module the selected test
  references (otherwise `mix test <files>` would fail on it). Tests the map
  marks `:always` or `:ast` (the AST fallback misses `use`-injected
  references), and test files the map does not know at all, are selected
  whenever there is any seed (`MixAffected.Run` turns selecting an unknown or
  stale entry into a full run). The walk is breadth-first in sorted order, so
  each selected test's explain chain is one shortest path `changed file -> ... -> test`.
  """

  alias MixAffected.Config
  alias MixAffected.Glob
  alias MixAffected.Graph
  alias MixAffected.TestMap

  @type path :: Graph.path()
  @type result :: %{tests: [path], explain: %{optional(path) => [path]}}

  @doc """
  `test_files` are the test files that exist now; map entries for other
  files are ignored. `graph` may be `nil` when every seed is a test file.
  """
  @spec select(Graph.t() | nil, [path], [path], TestMap.t(), Config.t(), [path]) :: result()
  def select(
        graph,
        seeds,
        test_files,
        %TestMap{tests: entries},
        %Config{} = config,
        read_only \\ []
      ) do
    entries = Map.take(entries, test_files)
    neighbors = neighbors(graph, entries, test_files, seeds, config)
    parents = walk(Enum.sort(seeds), neighbors)
    tests = MapSet.new(test_files)
    parents = read_only(Enum.sort(read_only), readers(entries, test_files), parents)

    always =
      if seeds == [],
        do: [],
        else: Enum.filter(test_files, &always?(Map.get(entries, &1)))

    reached = for {file, _} <- parents, MapSet.member?(tests, file), do: file
    {selected, parents} = load_closure(Enum.sort(Enum.uniq(reached ++ always)), entries, parents)

    %{tests: selected, explain: Map.new(selected, &{&1, chain(parents, &1)})}
  end

  # An `:ast` entry misses whatever macros (`use`) inject, so it cannot vouch
  # for its refs either.
  defp always?(nil), do: true
  defp always?(%{mode: mode}), do: mode in [:ast, :always]

  # A selected test that references a module defined in another test file
  # cannot run without that file loaded: select it too, parented by the test.
  defp load_closure(selected, entries, parents) do
    needs = fn test ->
      entries
      |> Map.get(test, %{refs: []})
      |> Map.fetch!(:refs)
      |> Enum.filter(&Map.has_key?(entries, &1))
    end

    {set, parents} = close(selected, needs, MapSet.new(selected), parents)
    {Enum.sort(set), parents}
  end

  defp close([], _needs, set, parents), do: {set, parents}

  defp close([test | rest], needs, set, parents) do
    new = test |> needs.() |> Enum.reject(&MapSet.member?(set, &1))
    parents = Enum.reduce(new, parents, &Map.put_new(&2, &1, test))
    close(rest ++ new, needs, Enum.into(new, set), parents)
  end

  defp neighbors(graph, entries, test_files, seeds, config) do
    by_ref =
      for {test, %{refs: refs}} <- entries, ref <- refs, ref != test, reduce: %{} do
        acc -> Map.update(acc, ref, [test], &[test | &1])
      end

    globbed = for {test, %{affected_by: [_ | _] = globs}} <- entries, do: {test, globs}
    unresolved = for {test, %{unresolved: [_ | _]}} <- entries, do: test
    readers = readers(entries, [])
    # Any changed or deleted file may have defined the modules a test can no
    # longer resolve: a map built after the change has no ref to the file.
    seed_set = MapSet.new(seeds)

    mapped =
      for {source_glob, test_globs} <- config.mappings,
          do: {source_glob, Enum.filter(test_files, &Glob.find(test_globs, &1))}

    fn file ->
      Enum.concat([
        graph_dependents(graph, file),
        Map.get(by_ref, file, []),
        for({test, globs} <- globbed, Glob.find(globs, file), do: test),
        for({glob, tests} <- mapped, Glob.match?(glob, file), test <- tests, do: test),
        if(MapSet.member?(seed_set, file), do: unresolved ++ reading(readers, file), else: [])
      ])
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  # {test, reads globs}; a test file the map does not know may read anything.
  defp readers(entries, test_files) do
    known = for {test, %{reads: [_ | _] = globs}} <- entries, do: {test, globs}
    known ++ for(test <- test_files, not Map.has_key?(entries, test), do: {test, ["**"]})
  end

  defp reading(readers, file), do: for({test, globs} <- readers, Glob.find(globs, file), do: test)

  defp read_only(files, readers, parents) do
    for file <- files, test <- reading(readers, file), reduce: parents do
      acc -> acc |> Map.put_new(file, nil) |> Map.put_new(test, file)
    end
  end

  defp graph_dependents(nil, _file), do: []

  defp graph_dependents(%Graph{dependents: dependents}, file),
    do: dependents |> Map.get(file, MapSet.new()) |> MapSet.to_list()

  # Breadth-first from the seeds; returns %{reached_file => parent | nil}.
  defp walk(seeds, neighbors) do
    parents = Map.new(seeds, &{&1, nil})
    walk(:queue.from_list(seeds), neighbors, parents)
  end

  defp walk(queue, neighbors, parents) do
    case :queue.out(queue) do
      {:empty, _} ->
        parents

      {{:value, file}, rest} ->
        new = Enum.reject(neighbors.(file), &Map.has_key?(parents, &1))
        parents = Enum.reduce(new, parents, &Map.put(&2, &1, file))
        walk(Enum.reduce(new, rest, &:queue.in/2), neighbors, parents)
    end
  end

  defp chain(parents, file), do: chain(parents, file, [])
  defp chain(parents, file, acc) when is_map_key(parents, file), do: up(parents, file, acc)
  defp chain(_parents, file, acc), do: [file | acc]

  defp up(parents, file, acc) do
    case Map.fetch!(parents, file) do
      nil -> [file | acc]
      parent -> up(parents, parent, [file | acc])
    end
  end
end
