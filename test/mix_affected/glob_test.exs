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

  test "compile/1 returns the anchored regex, or an error for unbalanced braces instead of raising" do
    assert {:ok, regex} = Glob.compile("lib/**/*.{ex,heex}")
    assert Regex.match?(regex, "lib/web/page.heex")

    for glob <- ["{a,b", "lib/{a,{b}", "a}", "lib/{a,b}}.ex"] do
      assert {:error, message} = Glob.compile(glob), glob
      assert message =~ inspect(glob)
    end
  end

  test "compile/1 returns an error for a glob that is not valid UTF-8 instead of raising" do
    glob = <<"lib/", 0xFF>>
    assert {:error, message} = Glob.compile(glob)
    assert message =~ "not valid UTF-8"
  end

  test "literal?/1 is true only for a pattern with no glob metacharacters" do
    assert Glob.literal?("lib/my_app/workers")
    assert Glob.literal?("mix.exs")
    refute Glob.literal?("lib/**")
    refute Glob.literal?("lib/?.ex")
    refute Glob.literal?("lib/*.{ex,exs}")
  end
end
