defmodule MixAffected.CLIIntegrationTest do
  # The affected.* tasks run as CI runs them: `mix <task>` in a compiled
  # fixture project that depends on this library, with the real graph and the
  # real tracer-built test map.
  use ExUnit.Case, async: false

  alias MixAffected.FixtureProject

  setup_all do
    %{dir: FixtureProject.compiled!("single_app")}
  end

  defp files(dir, changed, args \\ []),
    do:
      FixtureProject.mix(dir, ["affected.files", "--files", "-" | args],
        stdin: Enum.join(changed, "\n")
      )

  defp json!(%{status: status, stdout: stdout}, expected_status \\ 0) do
    assert status == expected_status
    JSON.decode!(stdout)
  end

  # ExUnit's run summary: "3 tests, 0 failures" before Elixir 1.20, "Result: 3 passed" or
  # "Result: 0/1 passed" from 1.20.
  defp summary(total, failed) do
    tests = if total == 1, do: "test", else: "tests"
    failures = if failed == 1, do: "failure", else: "failures"
    result = if failed == 0, do: "#{total} passed", else: "#{total - failed}/#{total} passed"
    ~r/(\b#{total} #{tests}, #{failed} #{failures}\b|Result: #{result}\n)/
  end

  defp tests(dir, changed), do: json!(files(dir, changed, ["--format", "json"]))["tests"]

  describe "selection through the real graph and test map" do
    test "a leaf module change selects only the tests of it and its dependents", %{dir: dir} do
      result = files(dir, ["lib/single_app/leaf.ex"])
      assert result.status == 0

      assert result.stdout ==
               """
               test/single_app/direct_test.exs
               test/single_app/leaf_test.exs
               test/single_app/transitive_test.exs
               """

      assert result.stderr =~ "3 of 15 test files affected"
    end

    test "a change to a use/require macro module propagates to the tests of its users",
         %{dir: dir} do
      assert tests(dir, ["lib/single_app/macros.ex"]) == [
               "test/single_app/requires_macros_test.exs",
               "test/single_app/uses_macros_test.exs"
             ]
    end

    test "a test/support change selects the tests using it", %{dir: dir} do
      assert tests(dir, ["test/support/user_factory.ex"]) == ["test/single_app/factory_test.exs"]

      assert tests(dir, ["lib/single_app/user.ex"]) == [
               "test/single_app/factory_test.exs",
               "test/single_app/user_name_test.exs"
             ]
    end

    test "@affected_by, @moduletag affected_by:, helper modules in test files and config mappings select tests",
         %{dir: dir} do
      assert tests(dir, ["lib/single_app/pong.ex"]) == [
               "test/single_app/dynamic_test.exs",
               "test/single_app/helpers_test.exs",
               "test/single_app/uses_helpers_test.exs"
             ]

      assert tests(dir, ["lib/single_app/standalone.ex"]) == [
               "test/single_app/mapped_contract_test.exs",
               "test/single_app/standalone_test.exs",
               "test/single_app/tagged_test.exs"
             ]
    end

    test "a source-scanning test is selected by a change to a file it reads but never references",
         %{dir: dir} do
      # A guard test that scans lib/** with File.read! must not be skipped.
      assert tests(dir, ["lib/single_app/guarded/policy.ex"]) == [
               "test/single_app/source_guard_test.exs"
             ]

      refute "test/single_app/source_guard_test.exs" in tests(dir, ["lib/single_app/leaf.ex"])
    end

    test "a changed test is selected with the test files it needs loaded", %{dir: dir} do
      assert tests(dir, ["test/single_app/uses_helpers_test.exs"]) == [
               "test/single_app/helpers_test.exs",
               "test/single_app/uses_helpers_test.exs"
             ]
    end

    test "a protocol impl in its own file selects the tests reaching its struct", %{dir: dir} do
      doc =
        json!(files(dir, ["lib/single_app/bag_enumerable.ex"], ["--format", "json", "--explain"]))

      assert doc["affected_files"] == [
               "lib/single_app/bag.ex",
               "lib/single_app/bag_enumerable.ex",
               "lib/single_app/bag_size.ex"
             ]

      assert doc["tests"] == ["test/single_app/bag_size_test.exs"]

      assert doc["explain"]["test/single_app/bag_size_test.exs"] == [
               "lib/single_app/bag_enumerable.ex",
               "lib/single_app/bag.ex",
               "lib/single_app/bag_size.ex",
               "test/single_app/bag_size_test.exs"
             ]
    end

    test "config and lockfile changes force a full run", %{dir: dir} do
      for {file, glob} <- [{"config/config.exs", "config/**"}, {"mix.lock", "mix.lock"}] do
        doc = json!(files(dir, ["lib/single_app/leaf.ex", file], ["--format", "json"]))
        assert doc["full_run"] == true
        assert doc["reason"] == "global_invalidation:#{glob}:#{file}"
        assert doc["tests"] == []
      end
    end

    test "a deleted lib file or an uncompiled resource forces a full run", %{dir: dir} do
      doc = json!(files(dir, ["lib/single_app/gone.ex"], ["--format", "json"]))
      assert %{"full_run" => true, "reason" => "unmapped_file:lib/single_app/gone.ex"} = doc

      doc = json!(files(dir, [".formatter.exs"], ["--format", "json"]))
      assert %{"full_run" => true, "reason" => "unmapped_file:.formatter.exs"} = doc
    end

    test "an ignored markdown change is an empty selection", %{dir: dir} do
      result = files(dir, ["README.md", "docs/guide.md"])
      assert %{status: 0, stdout: ""} = result
      assert result.stderr =~ "no affected tests"
      assert tests(dir, ["README.md"]) == []
    end

    test "a full run prints nothing on stdout in text mode and the reason on stderr",
         %{dir: dir} do
      result = files(dir, ["mix.lock"])
      assert %{status: 0, stdout: ""} = result
      assert result.stderr =~ "full run (global_invalidation:mix.lock:mix.lock)"
    end
  end

  describe "output contract" do
    test "JSON carries exactly the v1 fields", %{dir: dir} do
      doc = json!(files(dir, ["lib/single_app/leaf.ex"], ["--format", "json"]))

      assert doc == %{
               "schema_version" => 1,
               "full_run" => false,
               "reason" => nil,
               "changed_files" => ["lib/single_app/leaf.ex"],
               "affected_files" => [
                 "lib/single_app/direct.ex",
                 "lib/single_app/leaf.ex",
                 "lib/single_app/transitive.ex"
               ],
               "tests" => [
                 "test/single_app/direct_test.exs",
                 "test/single_app/leaf_test.exs",
                 "test/single_app/transitive_test.exs"
               ],
               "total_test_files" => 15,
               "graph_source" => graph_source(),
               "explain" => %{}
             }
    end

    test "--explain gives each test's chain in JSON and text", %{dir: dir} do
      doc = json!(files(dir, ["lib/single_app/leaf.ex"], ["--format", "json", "--explain"]))

      assert doc["explain"]["test/single_app/transitive_test.exs"] == [
               "lib/single_app/leaf.ex",
               "lib/single_app/direct.ex",
               "lib/single_app/transitive.ex",
               "test/single_app/transitive_test.exs"
             ]

      assert doc["explain"]["test/single_app/leaf_test.exs"] ==
               ["lib/single_app/leaf.ex", "test/single_app/leaf_test.exs"]

      text = files(dir, ["lib/single_app/leaf.ex"], ["--explain"]).stdout
      assert text =~ "lib/single_app/leaf.ex -> test/single_app/leaf_test.exs\n"
    end

    test "--output writes the document to a file and nothing to stdout", %{dir: dir} do
      output = Path.join(dir, "out/selection.json")
      result = files(dir, ["lib/single_app/leaf.ex"], ["--format", "json", "--output", output])
      assert %{status: 0, stdout: ""} = result
      assert %{"tests" => [_, _, _]} = output |> File.read!() |> JSON.decode!()
    end

    test "--files reads a file of paths", %{dir: dir} do
      list = Path.join(dir, "changed.txt")
      File.write!(list, "lib/single_app/macros.ex\n\n")
      result = FixtureProject.mix(dir, ["affected.files", "--files", list])
      assert result.stdout =~ "test/single_app/uses_macros_test.exs\n"
    end

    test "usage errors exit 1", %{dir: dir} do
      for args <- [
            [],
            ["--files", "-", "--base", "main"],
            ["--files", "-", "--bogus"],
            ["--files", "-", "--format", "yaml"],
            ["--files", "missing.txt"],
            ["--files", "-", "extra"]
          ] do
        result = FixtureProject.mix(dir, ["affected.files" | args])
        assert result.status == 1, "#{inspect(args)}: #{result.stderr}"
        assert result.stderr =~ "mix_affected:"
      end
    end
  end

  test "--map uses or builds the test map at the given path" do
    dir = FixtureProject.compiled!("single_app")
    map = Path.join(dir, "prebuilt/test_map.etf")

    assert tests(dir, ["lib/single_app/leaf.ex"]) |> length() == 3
    refute File.exists?(map)

    result = files(dir, ["lib/single_app/leaf.ex"], ["--map", map])
    assert result.status == 0
    assert File.exists?(map)
  end

  test "deleting a test file that defines helpers selects the tests that used them" do
    # The map is built after the deletion, as in CI; a map built before it
    # has a stale entry for the consumer (a ref is gone), which is a full run.
    dir = FixtureProject.compiled!("single_app")
    File.rm!(Path.join(dir, "test/single_app/helpers_test.exs"))

    assert tests(dir, ["test/single_app/helpers_test.exs"]) == [
             "test/single_app/uses_helpers_test.exs"
           ]
  end

  test "a prebuilt map whose entry for a selected test is stale is a full run" do
    dir = FixtureProject.compiled!("single_app")
    map = Path.join(dir, "prebuilt/test_map.etf")
    assert FixtureProject.mix(dir, ["affected.map", "--map", map]).status == 0

    # After the map was built: standalone_test starts using a helper defined
    # in helpers_test.exs. Its stale entry has no ref to that file, so a
    # selection would run it without the helper loaded and fail.
    File.write!(Path.join(dir, "test/single_app/standalone_test.exs"), """
    defmodule SingleApp.StandaloneTest do
      use ExUnit.Case, async: true

      test "value", do: assert(SingleApp.TestHelpers.rally() == :done)
    end
    """)

    doc =
      files(dir, ["test/single_app/standalone_test.exs"], ["--format", "json", "--map", map])
      |> json!(2)

    assert %{
             "full_run" => true,
             "reason" => "test_map_unavailable:stale_entry:test/single_app/standalone_test.exs",
             "tests" => []
           } = doc
  end

  test "a prebuilt map whose entry's refs changed since is a full run on any change" do
    dir = FixtureProject.compiled!("single_app")
    map = Path.join(dir, "prebuilt/test_map.etf")
    assert FixtureProject.mix(dir, ["affected.map", "--map", map]).status == 0

    # Outside the change set under selection, user_name.ex (a ref of
    # user_name_test) changes after the map was built.
    user_name = Path.join(dir, "lib/single_app/user_name.ex")
    File.write!(user_name, File.read!(user_name) <> "\n")

    doc =
      files(dir, ["lib/single_app/rally.ex"], ["--format", "json", "--map", map]) |> json!(2)

    assert %{
             "full_run" => true,
             "reason" => "test_map_unavailable:stale_entry:test/single_app/user_name_test.exs"
           } = doc
  end

  test "a map in an unknown format is rebuilt, not trusted" do
    dir = FixtureProject.compiled!("single_app")
    map = Path.join(dir, "prebuilt/test_map.etf")
    File.mkdir_p!(Path.dirname(map))
    File.write!(map, :erlang.term_to_binary({MixAffected.TestMap, 1, %{}}))

    doc = json!(files(dir, ["lib/single_app/leaf.ex"], ["--format", "json", "--map", map]))
    assert %{"full_run" => false, "tests" => [_, _, _]} = doc
    assert {:ok, _} = MixAffected.TestMap.read(map)
  end

  test "a protocol impl for a type outside the project forces a full run" do
    dir = FixtureProject.compiled!("single_app")

    File.write!(Path.join(dir, "lib/single_app/sizer.ex"), """
    defprotocol SingleApp.Sizer do
      def size(term)
    end
    """)

    File.write!(Path.join(dir, "lib/single_app/sizer_integer.ex"), """
    defimpl SingleApp.Sizer, for: Integer do
      def size(_integer), do: 1
    end
    """)

    # Changed directly, or reached through the closure (the impl calls Leaf).
    doc = json!(files(dir, ["lib/single_app/sizer_integer.ex"], ["--format", "json"]))

    assert %{"full_run" => true, "reason" => "unmapped_file:lib/single_app/sizer_integer.ex"} =
             doc

    File.write!(Path.join(dir, "lib/single_app/sizer_integer.ex"), """
    defimpl SingleApp.Sizer, for: Integer do
      def size(_integer), do: SingleApp.Leaf.value()
    end
    """)

    doc = json!(files(dir, ["lib/single_app/leaf.ex"], ["--format", "json"]))

    assert %{"full_run" => true, "reason" => "unmapped_file:lib/single_app/sizer_integer.ex"} =
             doc
  end

  test "a protocol impl the map does not know (added after a prebuilt map) forces a full run" do
    dir = FixtureProject.compiled!("single_app")
    map = Path.join(dir, "prebuilt/test_map.etf")
    assert FixtureProject.mix(dir, ["affected.map", "--map", map]).status == 0

    File.write!(Path.join(dir, "lib/single_app/bag_inspect.ex"), """
    defimpl Inspect, for: SingleApp.Bag do
      def inspect(_bag, _opts), do: "#Bag<>"
    end
    """)

    doc =
      json!(files(dir, ["lib/single_app/bag_inspect.ex"], ["--format", "json", "--map", map]))

    assert %{"full_run" => true, "reason" => "unmapped_file:lib/single_app/bag_inspect.ex"} = doc
  end

  test "deleting a helper-defining test file before the map is built still selects its users" do
    dir = FixtureProject.compiled!("single_app")
    File.rm!(Path.join(dir, "test/single_app/helpers_test.exs"))

    assert tests(dir, ["test/single_app/helpers_test.exs"]) == [
             "test/single_app/uses_helpers_test.exs"
           ]
  end

  test "removing a helper module from a test file that stays selects the tests that used it" do
    dir = FixtureProject.compiled!("single_app")

    File.write!(Path.join(dir, "test/single_app/helpers_test.exs"), """
    defmodule SingleApp.HelpersTest do
      use ExUnit.Case, async: true

      test "rally", do: assert(SingleApp.Rally.start() == :done)
    end
    """)

    assert tests(dir, ["test/single_app/helpers_test.exs"]) == [
             "test/single_app/helpers_test.exs",
             "test/single_app/uses_helpers_test.exs"
           ]
  end

  test "removing a module from a lib file that stays selects the tests that still call it" do
    dir = FixtureProject.compiled!("single_app")

    File.write!(Path.join(dir, "lib/single_app/standalone.ex"), """
    defmodule SingleApp.Solo do
      def value, do: :solo
    end
    """)

    assert tests(dir, ["lib/single_app/standalone.ex"]) == [
             "test/single_app/mapped_contract_test.exs",
             "test/single_app/standalone_test.exs",
             "test/single_app/tagged_test.exs"
           ]
  end

  test "a graph that cannot be built is a full run with exit status 2" do
    dir = FixtureProject.compiled!("single_app")
    File.write!(Path.join(dir, "lib/single_app/leaf.ex"), "defmodule SingleApp.Leaf do\n")

    result = files(dir, ["lib/single_app/leaf.ex"], ["--format", "json"])
    doc = json!(result, 2)
    assert doc["full_run"] == true
    assert doc["reason"] =~ ~r/^graph_unavailable:xref_failed:\d+$/
    assert doc["tests"] == []
  end

  test "a directory or malformed glob in the affected: config is a usage error naming the fix" do
    dir = FixtureProject.compiled!("single_app")
    mix_exs = Path.join(dir, "mix.exs")
    original = File.read!(mix_exs)
    mapping = ~s|{"lib/single_app/standalone.ex", ["test/single_app/mapped_*_test.exs"]}|

    for {bad_mapping, expected} <- [
          {~s|{"lib/single_app/guarded", ["test/single_app/mapped_*_test.exs"]}|,
           ~s|"lib/single_app/guarded/**"|},
          {~s|{"lib/single_app/{standalone,leaf.ex", ["test/**"]}|,
           ~s|"lib/single_app/{standalone,leaf.ex"|}
        ] do
      File.write!(mix_exs, String.replace(original, mapping, bad_mapping))

      result = files(dir, ["lib/single_app/guarded/policy.ex"], ["--format", "json"])
      assert result.status == 1, result.stderr
      assert result.stderr =~ "mix_affected: affected: mappings"
      assert result.stderr =~ expected
      assert result.stdout == ""
    end
  end

  test "a bad affected_by glob in one test file always runs that test and selection still succeeds" do
    dir = FixtureProject.compiled!("single_app")

    File.write!(Path.join(dir, "test/single_app/brace_test.exs"), """
    defmodule SingleApp.BraceTest do
      use ExUnit.Case, async: true
      @moduletag affected_by: ["lib/single_app/{pong,ping.ex"]

      test "x", do: assert(SingleApp.Leaf.value())
    end
    """)

    result = files(dir, ["lib/single_app/pong.ex"], ["--format", "json"])
    doc = json!(result)
    assert doc["full_run"] == false

    assert doc["tests"] == [
             "test/single_app/brace_test.exs",
             "test/single_app/dynamic_test.exs",
             "test/single_app/helpers_test.exs",
             "test/single_app/uses_helpers_test.exs"
           ]

    assert result.stderr =~
             ~r/mix_affected: warning: test\/single_app\/brace_test\.exs: .*always runs/

    # Only the bad file falls back: the others keep their precise selection.
    refute "test/single_app/dynamic_test.exs" in tests(dir, ["lib/single_app/leaf.ex"])
  end

  describe "--base" do
    setup do
      dir = FixtureProject.compiled!("single_app")
      git!(dir, ["init", "-q", "-b", "main"])
      File.write!(Path.join(dir, ".gitignore"), "/_build/\n/deps/\n")
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-q", "-m", "base"])
      git!(dir, ["checkout", "-q", "-b", "feature"])
      %{dir: dir}
    end

    defp git!(dir, args) do
      env = [
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@example.com"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@example.com"}
      ]

      {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
      out
    end

    defp base(dir),
      do: json!(FixtureProject.mix(dir, ["affected.files", "--base", "main", "--format", "json"]))

    test "unions committed, uncommitted and untracked changes", %{dir: dir} do
      File.write!(
        Path.join(dir, "lib/single_app/direct.ex"),
        File.read!(Path.join(dir, "lib/single_app/direct.ex")) <> "\n"
      )

      git!(dir, ["commit", "-q", "-am", "touch direct"])

      File.write!(
        Path.join(dir, "lib/single_app/macros.ex"),
        File.read!(Path.join(dir, "lib/single_app/macros.ex")) <> "\n"
      )

      File.write!(Path.join(dir, "test/single_app/new_test.exs"), """
      defmodule SingleApp.NewTest do
        use ExUnit.Case
        test "new", do: assert(true)
      end
      """)

      doc = base(dir)

      assert doc["changed_files"] == [
               "lib/single_app/direct.ex",
               "lib/single_app/macros.ex",
               "test/single_app/new_test.exs"
             ]

      assert doc["tests"] == [
               "test/single_app/direct_test.exs",
               "test/single_app/new_test.exs",
               "test/single_app/requires_macros_test.exs",
               "test/single_app/transitive_test.exs",
               "test/single_app/uses_macros_test.exs"
             ]
    end

    test "a moved lib file forces a full run on its old path", %{dir: dir} do
      git!(dir, ["mv", "lib/single_app/standalone.ex", "lib/single_app/alone.ex"])
      git!(dir, ["commit", "-q", "-m", "move"])

      assert %{"full_run" => true, "reason" => "unmapped_file:lib/single_app/standalone.ex"} =
               base(dir)
    end

    test "a ref git does not know is a usage error", %{dir: dir} do
      result = FixtureProject.mix(dir, ["affected.files", "--base", "no-such-ref"])
      assert result.status == 1
      assert result.stderr =~ "no-such-ref"
    end

    test "an empty, blank or option-like base is a usage error before any diff", %{dir: dir} do
      touch!(Path.join(dir, "lib/single_app/leaf.ex"))
      git!(dir, ["commit", "-q", "-am", "touch leaf"])

      for args <- [["--base", ""], ["--base", " "], ["--base=--output=out"]] do
        result = FixtureProject.mix(dir, ["affected.files" | args] ++ ["--format", "json"])
        assert result.status == 1
        assert result.stderr =~ ~r/mix_affected: (--base is empty|invalid --base)/
        refute result.stdout =~ ~s("tests")
      end

      refute File.exists?(Path.join(dir, "out...HEAD"))
    end

    test "a base with no merge base with HEAD is a usage error, never an empty selection",
         %{dir: dir} do
      git!(dir, ["checkout", "-q", "--orphan", "lonely"])
      git!(dir, ["commit", "-q", "-m", "unrelated history"])

      result = FixtureProject.mix(dir, ["affected.files", "--base", "main", "--format", "json"])
      assert result.status == 1
      assert result.stderr =~ "mix_affected: git diff"
      assert result.stderr =~ "main...HEAD"
      assert result.stderr =~ "no merge base"
      refute result.stdout =~ ~s("tests")
    end
  end

  defp touch!(path), do: File.write!(path, File.read!(path) <> "\n")

  describe "--base with the project in a subdirectory of the repository" do
    setup do
      repo =
        Path.join(System.tmp_dir!(), "mix_affected_repo_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(repo) end)
      File.mkdir_p!(Path.join(repo, "other"))
      File.write!(Path.join(repo, "other/x.txt"), "x\n")
      app = Path.join(repo, "app")
      File.rename!(FixtureProject.copy!("single_app"), app)
      FixtureProject.compile!(app)

      git!(repo, ["init", "-q", "-b", "main"])
      File.write!(Path.join(repo, ".gitignore"), "_build/\ndeps/\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "base"])
      git!(repo, ["checkout", "-q", "-b", "feature"])
      %{repo: repo, app: app}
    end

    test "paths inside the project are re-rooted from the repository top level", %{app: app} do
      touch!(Path.join(app, "lib/single_app/leaf.ex"))
      git!(app, ["commit", "-q", "-am", "touch leaf"])
      touch!(Path.join(app, "lib/single_app/direct.ex"))

      File.write!(Path.join(app, "test/single_app/new_test.exs"), """
      defmodule SingleApp.NewTest do
        use ExUnit.Case
        test "new", do: assert(true)
      end
      """)

      doc = base(app)

      assert doc["full_run"] == false

      assert doc["changed_files"] == [
               "lib/single_app/direct.ex",
               "lib/single_app/leaf.ex",
               "test/single_app/new_test.exs"
             ]

      assert "test/single_app/leaf_test.exs" in doc["tests"]
      assert "test/single_app/direct_test.exs" in doc["tests"]
      assert "test/single_app/new_test.exs" in doc["tests"]
    end

    test "a change outside the project forces a full run naming its absolute path",
         %{repo: repo, app: app} do
      touch!(Path.join(app, "lib/single_app/leaf.ex"))
      touch!(Path.join(repo, "other/x.txt"))
      git!(repo, ["commit", "-q", "-am", "touch leaf and a sibling"])

      doc = base(app)
      # git and the task's cwd both report the physical path (/private/var on macOS).
      top = repo |> git!(["rev-parse", "--show-toplevel"]) |> String.trim()
      outside = Path.join(top, "other/x.txt")

      assert doc["full_run"] == true
      assert doc["changed_files"] == Enum.sort([outside, "lib/single_app/leaf.ex"])
      assert doc["reason"] == "unmapped_file:#{outside}"
    end
  end

  describe "affected.test" do
    defp affected_test(dir, changed, passthrough) do
      FixtureProject.mix(dir, ["affected.test", "--files", "-", "--" | passthrough],
        stdin: Enum.join(changed, "\n")
      )
    end

    test "runs mix test on the selection with the passthrough args", %{dir: dir} do
      result = affected_test(dir, ["lib/single_app/leaf.ex"], ["--seed", "4242"])
      assert result.status == 0, result.stdout <> result.stderr
      assert result.stdout =~ "seed: 4242"
      assert result.stdout =~ summary(3, 0)
    end

    test "returns mix test's exit status" do
      dir = FixtureProject.compiled!("single_app")

      File.write!(Path.join(dir, "test/single_app/leaf_test.exs"), """
      defmodule SingleApp.LeafTest do
        use ExUnit.Case
        test "fails", do: assert(SingleApp.Leaf.value() == 0)
      end
      """)

      result = affected_test(dir, ["test/single_app/leaf_test.exs"], [])
      assert result.status != 0
      assert result.stdout =~ summary(1, 1)
    end

    test "an empty selection prints the notice and never starts ExUnit", %{dir: dir} do
      result = affected_test(dir, ["README.md"], [])
      assert result.status == 0
      assert result.stdout == "mix_affected: no affected tests\n"
    end

    test "a full run runs the whole suite", %{dir: dir} do
      result = affected_test(dir, ["mix.lock"], [])
      assert result.status == 0
      assert result.stdout =~ summary(15, 0)
      assert result.stderr =~ "full run (global_invalidation:mix.lock:mix.lock)"
    end
  end

  test "affected.report lists the failed test files a saved selection missed" do
    dir = FixtureProject.compiled!("single_app")
    selection = Path.join(dir, "selection.json")

    assert files(dir, ["lib/single_app/leaf.ex"], ["--format", "json", "--output", selection]).status ==
             0

    # A selected test and an unselected one fail in the full run.
    for {file, module} <- [{"leaf_test.exs", "Leaf"}, {"standalone_test.exs", "Standalone"}] do
      File.write!(Path.join(dir, "test/single_app/#{file}"), """
      defmodule SingleApp.#{module}Test do
        use ExUnit.Case
        test "fails", do: flunk("on purpose")
      end
      """)
    end

    assert FixtureProject.mix(dir, ["test"]).status != 0

    result =
      FixtureProject.mix(dir, ["affected.report", "--selection", selection, "--format", "json"])

    assert result.status == 0

    assert JSON.decode!(result.stdout) == %{
             "schema_version" => 1,
             "selection_full_run" => false,
             "failed_files" => [
               "test/single_app/leaf_test.exs",
               "test/single_app/standalone_test.exs"
             ],
             "missed_files" => ["test/single_app/standalone_test.exs"],
             "selected_count" => 3,
             "total_test_files" => 15
           }

    text = FixtureProject.mix(dir, ["affected.report", "--selection", selection])
    assert text.stdout == "test/single_app/standalone_test.exs\n"
  end

  test "affected.report without --selection is a usage error", %{dir: dir} do
    assert FixtureProject.mix(dir, ["affected.report"]).status == 1
  end

  test "an umbrella root is a full run: per-app test maps are not supported yet" do
    dir = FixtureProject.compiled!("umbrella")
    doc = json!(files(dir, ["apps/core/lib/core/account.ex"], ["--format", "json"]))

    assert %{
             "full_run" => true,
             "reason" => "test_map_unavailable:umbrella_not_supported",
             "graph_source" => "none"
           } = doc
  end

  defp graph_source do
    if Version.match?(System.version(), ">= 1.19.0"), do: "xref_json", else: "xref_dot"
  end
end
