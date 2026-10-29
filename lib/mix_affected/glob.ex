defmodule MixAffected.Glob do
  @moduledoc """
  Matches root-relative paths against shell-style globs without touching the
  filesystem, so deleted files match too.

    * `**` matches any run of characters, `/` included; `**/` also matches
      no directory at all (`**/*.md` matches `README.md`)
    * `*` matches any run of characters except `/`
    * `?` matches one character except `/`
    * `{a,b}` matches either alternative (alternatives may hold globs)

  A glob matches the whole path. A leading `./` is ignored on both sides.
  Every other character is literal, so a glob with no metacharacter matches
  exactly one path: `"lib/workers"` never matches `lib/workers/a.ex`
  (`literal?/1`; write `"lib/workers/**"`). Unbalanced braces are an error
  (`compile/1`), never a guess.
  """

  import Kernel, except: [match?: 2]

  @doc "Whether `path` matches `glob`; raises `ArgumentError` on a glob `compile/1` rejects."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(glob, path) do
    case compile(glob) do
      {:ok, regex} -> Regex.match?(regex, strip(path))
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Whether `path` matches any of `globs`; returns the first matching glob or `nil`."
  @spec find([String.t()], String.t()) :: String.t() | nil
  def find(globs, path), do: Enum.find(globs, &__MODULE__.match?(&1, path))

  @doc """
  Compiles `glob` to an anchored regex, or explains why it is malformed (a
  `{` never closed, a `}` never opened, bytes that are not valid UTF-8).
  Never raises.
  """
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def compile(glob) do
    with :ok <- utf8(glob),
         :ok <- balanced(glob, 0),
         {:ok, regex} <- Regex.compile("\\A" <> translate(strip(glob), 0) <> "\\z") do
      {:ok, regex}
    else
      {:error, {reason, _at}} -> {:error, "glob #{inspect(glob)} does not compile: #{reason}"}
      {:error, reason} -> {:error, "glob #{inspect(glob)} #{reason}"}
    end
  end

  @doc "Whether `glob` has no metacharacter (`*`, `?`, `{`), so it matches one path only."
  @spec literal?(String.t()) :: boolean()
  def literal?(glob), do: not String.contains?(glob, ["*", "?", "{"])

  defp utf8(glob),
    do: if(String.valid?(glob), do: :ok, else: {:error, "is not valid UTF-8"})

  defp balanced("", 0), do: :ok
  defp balanced("", _depth), do: {:error, ~s|has a "{" that is never closed|}
  defp balanced("{" <> rest, depth), do: balanced(rest, depth + 1)
  defp balanced("}" <> _rest, 0), do: {:error, ~s|has a "}" with no "{" before it|}
  defp balanced("}" <> rest, depth), do: balanced(rest, depth - 1)
  defp balanced(<<_byte, rest::binary>>, depth), do: balanced(rest, depth)

  defp strip("./" <> rest), do: strip(rest)
  defp strip(path), do: path

  # `depth` counts open braces, so `,` and `}` are only special inside them.
  defp translate("", _depth), do: ""
  defp translate("**/" <> rest, depth), do: "(?:.*/)?" <> translate(rest, depth)
  defp translate("**" <> rest, depth), do: ".*" <> translate(rest, depth)
  defp translate("*" <> rest, depth), do: "[^/]*" <> translate(rest, depth)
  defp translate("?" <> rest, depth), do: "[^/]" <> translate(rest, depth)
  defp translate("{" <> rest, depth), do: "(?:" <> translate(rest, depth + 1)
  defp translate("}" <> rest, depth) when depth > 0, do: ")" <> translate(rest, depth - 1)
  defp translate("," <> rest, depth) when depth > 0, do: "|" <> translate(rest, depth)

  defp translate(<<char::utf8, rest::binary>>, depth),
    do: Regex.escape(<<char::utf8>>) <> translate(rest, depth)
end
