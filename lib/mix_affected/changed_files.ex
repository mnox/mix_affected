defmodule MixAffected.ChangedFiles do
  @moduledoc """
  Where a change set comes from: `--files <path|->` or `--base <git-ref>`.

  From git, the change set is the union of

    * `git diff --name-only --no-renames <ref>...HEAD` (committed on the branch)
    * `git diff --name-only --no-renames HEAD` (staged and unstaged)
    * `git ls-files --others --exclude-standard` (untracked)

  `--no-renames` makes a moved file show as delete + add, so its old path
  forces a full run as an unmapped file. Paths are made relative to the
  project root (git reports them relative to the repository top level).
  """

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
    with {:ok, [top]} <- git(root, ["rev-parse", "--show-toplevel"]),
         {:ok, committed} <- git(root, ["diff", "--name-only", "--no-renames", "#{ref}...HEAD"]),
         {:ok, uncommitted} <- git(root, ["diff", "--name-only", "--no-renames", "HEAD"]),
         {:ok, untracked} <-
           git(root, ["ls-files", "--others", "--exclude-standard", "--full-name"]) do
      top = Path.expand(top)
      root = Path.expand(root)

      {:ok,
       (committed ++ uncommitted ++ untracked)
       |> Enum.map(&(top |> Path.join(&1) |> Path.relative_to(root)))
       |> Enum.uniq()
       |> Enum.sort()}
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
