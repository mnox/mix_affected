defmodule MixAffected.ChangedFiles do
  @moduledoc """
  Where a change set comes from: `--files <path|->` or `--base <git-ref>`.

  From git, the change set is the union of

    * `git diff --name-only --no-relative --no-renames <ref>...HEAD` (committed on the branch)
    * `git diff --name-only --no-relative --no-renames HEAD` (staged and unstaged)
    * `git ls-files --others --exclude-standard --full-name -- :/` (untracked)

  All three cover the whole repository, not only the project directory: a
  `diff.relative` config is overridden and untracked files are listed from
  the top level, so a project in a subdirectory still sees changes beside it.

  `--no-renames` makes a moved file show as delete + add, so its old path
  forces a full run as an unmapped file. Paths are made relative to the
  project root (git reports them relative to the repository top level); a
  changed file outside the project root stays absolute, which the classifier
  turns into a full run.

  The ref is checked before any diff: an empty or blank ref (git would read
  `...HEAD` as an empty range), an option-like ref (git would read it as an
  option, e.g. `--output=<file>`) and a ref that does not resolve to a commit
  are errors, never an empty change set. Every diff ends its revisions with
  `--`, so a ref is never read as a path. A ref with no merge base with
  `HEAD` (an unrelated history, or a shallow clone missing it) is an error.
  """

  # --no-relative overrides a diff.relative config, which would drop every
  # path outside the cwd and report the rest relative to it.
  @diff_opts ["--name-only", "--no-relative", "--no-renames"]

  @doc "Reads newline-separated paths from `path`, or stdin when `path` is `\"-\"`."
  @spec from_files(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def from_files("-") do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> {:ok, lines(data)}
      :eof -> {:ok, []}
      {:error, reason} -> {:error, "could not read --files from stdin: #{inspect(reason)}"}
    end
  end

  def from_files(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, lines(data)}
      {:error, posix} -> {:error, "could not read --files #{path}: #{:file.format_error(posix)}"}
    end
  end

  @doc "The change set of the working tree at `root` against `ref`."
  @spec from_git(Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def from_git(root, ref) do
    with :ok <- check_ref(ref),
         {:ok, [top]} <- git(root, ["rev-parse", "--show-toplevel"]),
         :ok <- resolve_commit(root, ref),
         {:ok, committed} <-
           git(root, ["diff" | @diff_opts] ++ ["#{ref}...HEAD", "--"]),
         {:ok, uncommitted} <- git(root, ["diff" | @diff_opts] ++ ["HEAD", "--"]),
         {:ok, untracked} <-
           git(root, ["ls-files", "--others", "--exclude-standard", "--full-name", "--", ":/"]) do
      top = Path.expand(top)
      root = Path.expand(root)

      {:ok,
       (committed ++ uncommitted ++ untracked)
       |> Enum.map(&(top |> Path.join(&1) |> Path.relative_to(root)))
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  defp check_ref(ref) do
    cond do
      String.trim(ref) == "" ->
        {:error, "--base is empty; give a git ref such as origin/main"}

      String.starts_with?(ref, "-") ->
        {:error, "invalid --base #{inspect(ref)}: a ref cannot start with \"-\""}

      true ->
        :ok
    end
  end

  defp resolve_commit(root, ref) do
    case git(root, ["rev-parse", "--verify", "--quiet", "--end-of-options", "#{ref}^{commit}"]) do
      {:ok, _sha} -> :ok
      {:error, _} -> {:error, "invalid --base #{inspect(ref)}: not a commit in this repository"}
    end
  end

  defp git(root, args) do
    case System.find_executable("git") do
      nil ->
        {:error, "--base needs git, which is not on PATH"}

      git ->
        case System.cmd(git, args, cd: root, stderr_to_stdout: true) do
          {out, 0} -> {:ok, lines(out)}
          {out, _} -> {:error, "git #{Enum.join(args, " ")} failed: #{String.trim(out)}"}
        end
    end
  end

  defp lines(data) do
    data |> String.split(["\r\n", "\n"]) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end
