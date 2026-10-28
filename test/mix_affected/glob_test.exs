defmodule MixAffected.GlobTest do
  use ExUnit.Case, async: true

  alias MixAffected.Glob

  test "** spans directories, including none" do
    assert Glob.match?("**/*.md", "README.md")
    assert Glob.match?("**/*.md", "docs/guides/intro.md")
    assert Glob.match?("config/**", "config/config.exs")
    assert Glob.match?("config/**", "config/env/prod.exs")
    assert Glob.match?("priv/repo/migrations/**", "priv/repo/migrations/2026_add.exs")
    refute Glob.match?("config/**", "lib/config/x.ex")
    refute Glob.match?("**/*.md", "README.markdown")
  end

  test "* and ? never cross a directory separator" do
    assert Glob.match?("test/*_test.exs", "test/foo_test.exs")
    refute Glob.match?("test/*_test.exs", "test/sub/foo_test.exs")
    assert Glob.match?("lib/?.ex", "lib/a.ex")
    refute Glob.match?("lib/?.ex", "lib/ab.ex")
  end

  test "a glob is anchored at both ends and literal characters are escaped" do
    assert Glob.match?("mix.exs", "mix.exs")
    refute Glob.match?("mix.exs", "apps/web/mix.exs")
    refute Glob.match?("mix.exs", "mixXexs")
    assert Glob.match?("lib/a+b(1).ex", "lib/a+b(1).ex")
  end

  test "braces are alternation" do
    assert Glob.match?("lib/**/*.{ex,heex}", "lib/web/page.heex")
    assert Glob.match?("lib/**/*.{ex,heex}", "lib/web/page.ex")
    refute Glob.match?("lib/**/*.{ex,heex}", "lib/web/page.exs")
  end

  test "a leading ./ is ignored on either side" do
    assert Glob.match?("./mix.lock", "mix.lock")
    assert Glob.match?("mix.lock", "./mix.lock")
  end
end
