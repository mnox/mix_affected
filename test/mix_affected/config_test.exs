defmodule MixAffected.ConfigTest do
  use ExUnit.Case, async: true

  alias MixAffected.Config

  @defaults [
    "config/**",
    "mix.exs",
    "mix.lock",
    "test/test_helper.exs",
    "priv/repo/migrations/**"
  ]

  test "defaults when the project has no affected config" do
    assert {:ok, config} = Config.from_project(app: :my_app)
    assert config.global_invalidation == @defaults
    assert config.ignore == ["*.md", "docs/**/*.md"]
    assert config.mappings == []
    assert config.test_paths == ["test"]
    assert config.test_pattern == "*_test.exs"
  end

  test "global_invalidation replaces the defaults and extra_global_invalidation appends" do
    assert {:ok, replaced} = Config.from_project(affected: [global_invalidation: ["mix.lock"]])
    assert replaced.global_invalidation == ["mix.lock"]

    assert {:ok, extended} =
             Config.from_project(affected: [extra_global_invalidation: ["rel/**"]])

    assert extended.global_invalidation == @defaults ++ ["rel/**"]
  end

  test "reads ignore, mappings and the project's test paths and pattern" do
    assert {:ok, config} =
             Config.from_project(
               test_paths: ["test", "integration"],
               test_pattern: "*_spec.exs",
               affected: [ignore: [], mappings: [{"lib/a/**", ["test/a/**"]}]]
             )

    assert config.ignore == []
    assert config.mappings == [{"lib/a/**", ["test/a/**"]}]
    assert config.test_paths == ["test", "integration"]
    assert config.test_pattern == "*_spec.exs"
  end

  test "rejects unknown keys and malformed values instead of guessing" do
    assert {:error, message} = Config.from_project(affected: [ignores: ["**/*.md"]])
    assert message =~ "ignores"
    assert {:error, _} = Config.from_project(affected: [ignore: "**/*.md"])
    assert {:error, _} = Config.from_project(affected: [mappings: [{"lib/**", "test/**"}]])
    assert {:error, _} = Config.from_project(affected: %{ignore: []})
  end

  test "test_file? follows test_paths and test_pattern" do
    {:ok, config} = Config.from_project([])
    assert Config.test_file?(config, "test/my_app/user_test.exs")
    assert Config.test_file?(config, "test/user_test.exs")
    refute Config.test_file?(config, "test/support/data_case.ex")
    refute Config.test_file?(config, "lib/my_app/user_test.exs")
    refute Config.test_file?(config, "test/test_helper.exs")
  end
end
