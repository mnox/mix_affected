defmodule MixAffected.ChangedFilesTest do
  use ExUnit.Case, async: true

  alias MixAffected.ChangedFiles

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git!(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "a.ex"), "a\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "base"])
    git!(dir, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(dir, "a.ex"), "b\n")
    git!(dir, ["commit", "-q", "-am", "change"])
    :ok
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

  describe "from_git/2 rejects a --base that cannot name the base commit" do
    test "an empty or blank ref, which git would read as an empty range", %{tmp_dir: dir} do
      for ref <- ["", " ", "\t\n"] do
        assert {:error, message} = ChangedFiles.from_git(dir, ref)
        assert message =~ "--base is empty"
      end
    end

    test "an option-like ref, which git would read as an option", %{tmp_dir: dir} do
      for ref <- ["--output=out", "-x", "-"] do
        assert {:error, message} = ChangedFiles.from_git(dir, ref)
        assert message == ~s(invalid --base #{inspect(ref)}: a ref cannot start with "-")
      end

      assert File.ls!(dir) |> Enum.reject(&(&1 in [".git", "a.ex"])) == []
    end

    test "a ref that does not resolve to a commit", %{tmp_dir: dir} do
      for ref <- ["no-such-ref", "main:a.ex", "main^{tree}"] do
        assert {:error, message} = ChangedFiles.from_git(dir, ref)
        assert message == "invalid --base #{inspect(ref)}: not a commit in this repository"
      end
    end
  end

  test "from_git/2 reads a ref that is also a path name as the ref", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "HEAD"), "a file named like the ref\n")
    File.write!(Path.join(dir, "main...HEAD"), "a file named like the range\n")

    assert ChangedFiles.from_git(dir, "main") == {:ok, ["HEAD", "a.ex", "main...HEAD"]}
  end

  describe "from_git/2 with the project in a subdirectory of the repository" do
    setup %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "app"))
      File.mkdir_p!(Path.join(dir, "other"))
      File.write!(Path.join(dir, "app/b.ex"), "b\n")
      File.write!(Path.join(dir, "other/t.txt"), "t\n")
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-q", "-m", "subdir"])
      top = dir |> git!(["rev-parse", "--show-toplevel"]) |> String.trim()
      %{app: Path.join(dir, "app"), top: top}
    end

    test "an untracked file outside the project stays in the change set, absolute",
         %{tmp_dir: dir, app: app, top: top} do
      File.write!(Path.join(dir, "other/new.ex"), "new\n")

      assert {:ok, changed} = ChangedFiles.from_git(app, "main")
      assert Path.join(top, "other/new.ex") in changed
    end

    test "diff.relative does not drop changes outside the project or mis-root those inside",
         %{tmp_dir: dir, app: app, top: top} do
      git!(dir, ["config", "diff.relative", "true"])
      File.write!(Path.join(dir, "other/t.txt"), "changed\n")
      File.write!(Path.join(dir, "app/b.ex"), "changed\n")

      assert {:ok, changed} = ChangedFiles.from_git(app, "main")
      assert Path.join(top, "other/t.txt") in changed
      assert "b.ex" in changed
      assert Path.join(top, "a.ex") in changed
    end
  end
end
