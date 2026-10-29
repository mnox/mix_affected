defmodule MixAffected.ConfigTest do
  use ExUnit.Case, async: true

  alias MixAffected.{Config, Glob}

  @root File.cwd!()

  @defaults [
    "config/**",
    "mix.exs",
    "mix.lock",
    "test/test_helper.exs",
    "priv/repo/migrations/**"
  ]

  test "defaults when the project has no affected config" do
    assert {:ok, config} = Config.from_project([app: :my_app], @root)
    assert config.global_invalidation == @defaults
    assert config.ignore == ["*.md", "docs/**/*.md"]
    assert config.mappings == []
    assert config.test_paths == ["test"]
    assert config.test_pattern == "*_test.exs"
  end

  test "global_invalidation replaces the defaults and extra_global_invalidation appends" do
    assert {:ok, replaced} =
             Config.from_project([affected: [global_invalidation: ["mix.lock"]]], @root)

    assert replaced.global_invalidation == ["mix.lock"]

    assert {:ok, extended} =
             Config.from_project([affected: [extra_global_invalidation: ["rel/**"]]], @root)

    assert extended.global_invalidation == @defaults ++ ["rel/**"]
  end

  test "reads ignore, mappings and the project's test paths and pattern" do
    assert {:ok, config} =
             Config.from_project(
               [
                 test_paths: ["test", "integration"],
                 test_pattern: "*_spec.exs",
                 affected: [ignore: [], mappings: [{"lib/a/**", ["test/a/**"]}]]
               ],
               @root
             )

    assert config.ignore == []
    assert config.mappings == [{"lib/a/**", ["test/a/**"]}]
    assert config.test_paths == ["test", "integration"]
    assert config.test_pattern == "*_spec.exs"
  end

  test "rejects unknown keys and malformed values instead of guessing" do
    assert {:error, message} = Config.from_project([affected: [ignores: ["**/*.md"]]], @root)
    assert message =~ "ignores"
    assert {:error, _} = Config.from_project([affected: [ignore: "**/*.md"]], @root)

    assert {:error, _} =
             Config.from_project([affected: [mappings: [{"lib/**", "test/**"}]]], @root)

    assert {:error, _} = Config.from_project([affected: %{ignore: []}], @root)
  end

  test "rejects a malformed glob in any key, naming it" do
    for affected <- [
          [ignore: ["{a,b"]],
          [global_invalidation: ["config/{dev,prod.exs"]],
          [extra_global_invalidation: ["rel}"]],
          [mappings: [{"lib/{a,b", ["test/**"]}]],
          [mappings: [{"lib/**", ["test/{a,b"]}]]
        ] do
      assert {:error, message} = Config.from_project([affected: affected], @root),
             inspect(affected)

      assert message =~ ~r/\{a,b|prod\.exs|rel\}/
      assert message =~ "affected:"
    end
  end

  @tag :tmp_dir
  test "rejects a directory pattern (glob-free, or any glob ending in /), suggesting dir/**", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "lib/my_app/workers"))
    File.write!(Path.join(root, "Dockerfile"), "")

    for {affected, suggestion} <- [
          {[mappings: [{"lib/my_app/workers", ["test/**"]}]], "lib/my_app/workers/**"},
          {[mappings: [{"lib/**", ["test/my_app/workers/"]}]], "test/my_app/workers/**"},
          {[ignore: ["priv/static/"]], "priv/static/**"},
          {[global_invalidation: ["./lib/my_app/workers"]], "lib/my_app/workers/**"},
          {[extra_global_invalidation: ["lib/my_app/workers/"]], "lib/my_app/workers/**"},
          {[ignore: ["./"]], "**"},
          {[mappings: [{"lib/my_app/workers/**/", ["test/**"]}]], "lib/my_app/workers/**"},
          {[global_invalidation: ["lib/*/"]], "lib/*/**"}
        ] do
      assert {:error, message} = Config.from_project([affected: affected], root),
             inspect(affected)

      assert message =~ inspect(suggestion), message
    end

    # A file literal, existing or not (deleted files still match), is fine.
    assert {:ok, _} =
             Config.from_project(
               [affected: [extra_global_invalidation: ["Dockerfile", "rel/vm.args"]]],
               root
             )
  end

  @tag :tmp_dir
  test "rejects a glob with a ., .. or empty segment, which no changed path matches, suggesting its normal form",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib/workers"))

    for {glob, suggestion} <- [
          {"lib/workers/.", "lib/workers/**"},
          {"lib/workers/./", "lib/workers/**"},
          {"lib/./workers/**", "lib/workers/**"},
          {"lib//workers/**", "lib/workers/**"},
          {"lib/../lib/workers/**", "lib/workers/**"},
          {"./lib/workers/./a.ex", "lib/workers/a.ex"},
          {"lib/workers/..", "lib/**"}
        ] do
      assert {:error, message} = Config.validate_glob(glob, root), glob
      assert message =~ "write #{inspect(suggestion)}", message
      assert Config.validate_glob(suggestion, root) == :ok, suggestion
      assert Glob.match?(suggestion, "lib/workers/a.ex"), suggestion
    end

    assert {:error, message} = Config.validate_glob("lib/../../shared/**", root)
    assert message =~ "outside the project root"

    assert {:error, message} =
             Config.from_project([affected: [mappings: [{"lib//workers/**", ["test/**"]}]]], root)

    assert message =~ ~s(affected: mappings: glob "lib//workers/**")
  end

  test "rejects a test_paths/test_pattern pair that does not compile, instead of raising later" do
    assert {:error, message} = Config.from_project([test_pattern: "*_test.{exs"], @root)
    assert message =~ "test_pattern"
    assert message =~ ~s("test/**/*_test.{exs")

    assert {:error, message} = Config.from_project([test_paths: ["test}"]], @root)
    assert message =~ "test_paths"
  end

  test "test_file? follows test_paths and test_pattern" do
    {:ok, config} = Config.from_project([], @root)
    assert Config.test_file?(config, "test/my_app/user_test.exs")
    assert Config.test_file?(config, "test/user_test.exs")
    refute Config.test_file?(config, "test/support/data_case.ex")
    refute Config.test_file?(config, "lib/my_app/user_test.exs")
    refute Config.test_file?(config, "test/test_helper.exs")
  end
end
