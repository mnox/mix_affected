defmodule MixAffected.ClassifierTest do
  use ExUnit.Case, async: true

  alias MixAffected.Classifier
  alias MixAffected.Config
  alias MixAffected.Graph

  @existing MapSet.new([
              "lib/app/leaf.ex",
              "lib/app/user.ex",
              "lib/app/page.html.heex",
              "test/app/leaf_test.exs",
              "test/support/factory.ex",
              "README.md",
              "priv/data/terms.md"
            ])

  defp config(affected \\ []) do
    {:ok, config} = Config.from_project([affected: affected], "/repo")
    config
  end

  defp classify(changed, config \\ config()),
    do: Classifier.classify(changed, config, "/repo", &MapSet.member?(@existing, &1))

  defp graph do
    Graph.new("/repo", %{
      "lib/app/leaf.ex" => %{},
      "lib/app/user.ex" => %{"lib/app/leaf.ex" => :runtime},
      "test/support/factory.ex" => %{"lib/app/user.ex" => :export}
    })
  end

  describe "classify/3" do
    test "normalizes the change set: trims, drops blanks and ./, dedupes, sorts" do
      c = classify([" lib/app/user.ex", "", "./lib/app/leaf.ex", "lib/app/user.ex\r"])
      assert c.changed == ["lib/app/leaf.ex", "lib/app/user.ex"]
    end

    test "canonicalizes paths against the root: ./, .., and absolute paths under it" do
      c =
        classify([
          "lib/./app/leaf.ex",
          "lib/app/../app/user.ex",
          "/repo/test/app/leaf_test.exs",
          "lib//app/leaf.ex"
        ])

      assert c.changed == ["lib/app/leaf.ex", "lib/app/user.ex", "test/app/leaf_test.exs"]
      assert c.sources == ["lib/app/leaf.ex", "lib/app/user.ex"]
      assert c.tests == ["test/app/leaf_test.exs"]
    end

    test "a path outside the root is unmapped" do
      assert classify(["lib/app/leaf.ex", "../other/lib/x.ex"]).full_run ==
               "unmapped_file:/other/lib/x.ex"

      assert classify(["/elsewhere/README.md"]).full_run == "unmapped_file:/elsewhere/README.md"
    end

    test "ignored files are dropped before anything else, even under a global glob" do
      c = classify(["README.md", "config/README.md"], config(ignore: ["**/*.md"]))
      assert c.ignored == ["README.md", "config/README.md"]
      assert c.full_run == nil
      assert c.sources == [] and c.tests == []
    end

    test "by default only root and docs/ markdown is ignored; other .md is unmapped" do
      c = classify(["README.md", "docs/guide.md", "docs/a/b.md"])
      assert c.ignored == ["README.md", "docs/a/b.md", "docs/guide.md"]
      assert c.full_run == nil

      assert classify(["lib/app/notes.md"]).full_run == "unmapped_file:lib/app/notes.md"
      c = classify(["priv/data/terms.md"])
      assert c.ignored == [] and c.sources == ["priv/data/terms.md"]
      assert Classifier.affected(c, graph()) == {:full_run, "unmapped_file:priv/data/terms.md"}
    end

    test "a global invalidation glob forces a full run naming the glob and the file" do
      for {file, glob} <- [
            {"config/runtime.exs", "config/**"},
            {"mix.exs", "mix.exs"},
            {"mix.lock", "mix.lock"},
            {"test/test_helper.exs", "test/test_helper.exs"},
            {"priv/repo/migrations/20260101_add.exs", "priv/repo/migrations/**"}
          ] do
        assert classify(["lib/app/leaf.ex", file]).full_run ==
                 "global_invalidation:#{glob}:#{file}"
      end
    end

    test "extra_global_invalidation globs force a full run too" do
      c = classify(["rel/env.sh.eex"], config(extra_global_invalidation: ["rel/**"]))
      assert c.full_run == "global_invalidation:rel/**:rel/env.sh.eex"
    end

    test "a global invalidation wins over an unmapped file regardless of order" do
      assert classify(["a_unknown.txt", "mix.lock"]).full_run ==
               "global_invalidation:mix.lock:mix.lock"
    end

    test "test/support is not a global invalidation: it is a source candidate" do
      c = classify(["test/support/factory.ex"])
      assert c.full_run == nil
      assert c.sources == ["test/support/factory.ex"]
    end

    test "a changed test file is selected directly; a deleted one is just dropped" do
      c = classify(["test/app/leaf_test.exs", "test/app/gone_test.exs"])
      assert c.tests == ["test/app/leaf_test.exs"]
      assert c.deleted_tests == ["test/app/gone_test.exs"]
      assert c.full_run == nil
    end

    test "a deleted non-test file forces a full run as unmapped" do
      assert classify(["lib/app/gone.ex"]).full_run == "unmapped_file:lib/app/gone.ex"
    end

    test "existing non-test files are source candidates for the graph to vouch for" do
      c = classify(["lib/app/page.html.heex", "lib/app/user.ex"])
      assert c.full_run == nil
      assert c.sources == ["lib/app/page.html.heex", "lib/app/user.ex"]
    end
  end

  describe "affected/2" do
    test "seeds Graph.dependents with the sources and adds the changed tests" do
      c = classify(["lib/app/leaf.ex", "test/app/leaf_test.exs"])

      assert Classifier.affected(c, graph()) ==
               {:ok,
                [
                  "lib/app/leaf.ex",
                  "lib/app/user.ex",
                  "test/app/leaf_test.exs",
                  "test/support/factory.ex"
                ]}
    end

    test "an existing file the graph does not compile (external resource) is unmapped" do
      c = classify(["lib/app/user.ex", "lib/app/page.html.heex"])

      assert Classifier.affected(c, graph()) ==
               {:full_run, "unmapped_file:lib/app/page.html.heex"}
    end

    test "with no sources the graph is not consulted" do
      c = classify(["test/app/leaf_test.exs"])
      assert Classifier.affected(c, nil) == {:ok, ["test/app/leaf_test.exs"]}
    end
  end
end
