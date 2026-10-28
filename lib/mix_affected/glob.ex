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
  """

  import Kernel, except: [match?: 2]

  @doc "Whether `path` matches `glob`."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(glob, path), do: Regex.match?(compile(glob), strip(path))

  @doc "Whether `path` matches any of `globs`; returns the first matching glob or `nil`."
  @spec find([String.t()], String.t()) :: String.t() | nil
  def find(globs, path), do: Enum.find(globs, &__MODULE__.match?(&1, path))

  @doc "Compiles `glob` to an anchored regex."
  @spec compile(String.t()) :: Regex.t()
  def compile(glob), do: Regex.compile!("\\A" <> translate(strip(glob), 0) <> "\\z")

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
