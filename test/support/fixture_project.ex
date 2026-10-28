defmodule MixAffected.FixtureProject do
  @moduledoc """
  Copies a fixture Mix project from `fixtures/` into a fresh temp dir and
  compiles it with `MIX_ENV=test`, so fixture `_build` never lands in the repo.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MixAffected.Graph.Source.Xref

  @fixtures Path.expand("../../fixtures", __DIR__)
  @tool_versions Path.expand("../../.tool-versions", __DIR__)
  @leaky_env ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_EXS MIX_LOCKFILE)

  @doc "The pristine source dir of fixture `name`."
  @spec fixture_path(String.t()) :: Path.t()
  def fixture_path(name), do: Path.join(@fixtures, name)

  @doc "Copies fixture `name` to a temp dir (removed on test exit) and returns its path."
  @spec copy!(String.t()) :: Path.t()
  def copy!(name) do
    dir =
      Path.join(System.tmp_dir!(), "mix_affected_#{name}_#{System.unique_integer([:positive])}")

    File.cp_r!(Path.join(@fixtures, name), dir)
    # The temp dir sits outside this repo, so carry the toolchain pin with it.
    File.cp!(@tool_versions, Path.join(dir, ".tool-versions"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "Compiles the project at `dir` in the test env (Hex deps first, when it has a lock); raises on failure."
  @spec compile!(Path.t()) :: Path.t()
  def compile!(dir) do
    if File.exists?(Path.join(dir, "mix.lock")), do: deps_get!(dir)

    case Xref.mix(dir, ["compile"], []) do
      {:ok, _log} -> dir
      {:error, reason} -> raise "fixture compile failed in #{dir}: #{inspect(reason)}"
    end
  end

  # Hex deps come from the local Hex cache against the fixture's lock, so the
  # suite normally needs no network. Hex versions bundled with different
  # Elixir releases share ~/.hex/cache.ets and evict each other's registry
  # entries, so a cache miss retries once online; the lock still pins versions.
  defp deps_get!(dir) do
    env = [{"MIX_ENV", "test"} | for(var <- @leaky_env, do: {var, nil})]

    result =
      case run_deps_get(dir, [{"HEX_OFFLINE", "1"} | env]) do
        {:error, log, _status} = offline_miss ->
          if log =~ "not cached locally", do: run_deps_get(dir, env), else: offline_miss

        :ok ->
          :ok
      end

    with {:error, log, status} <- result do
      raise "fixture deps.get failed in #{dir} (#{status}): #{log}"
    end
  end

  defp run_deps_get(dir, env) do
    case System.cmd("mix", ["deps.get"], cd: dir, env: env, stderr_to_stdout: true) do
      {_log, 0} -> :ok
      {log, status} -> {:error, log, status}
    end
  end

  @doc """
  Runs `mix <args>` in `dir` with `MIX_ENV=test`, as a CI step would, and
  returns its exit status with stdout and stderr kept apart. `:stdin` feeds
  the given string on stdin (otherwise stdin is empty); `:env` adds
  environment variables.
  """
  @spec mix(Path.t(), [String.t()], keyword()) :: %{
          status: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t()
        }
  def mix(dir, args, opts \\ []) do
    io = Path.join(System.tmp_dir!(), "mix_affected_io_#{System.unique_integer([:positive])}")
    File.mkdir_p!(io)
    [stdin, stdout, stderr] = for name <- ~w(stdin stdout stderr), do: Path.join(io, name)
    File.write!(stdin, Keyword.get(opts, :stdin, ""))

    env = env([{"MIX_ENV", "test"} | Keyword.get(opts, :env, [])])
    script = ~s(exec mix "$@" <"#{stdin}" >"#{stdout}" 2>"#{stderr}")

    try do
      {_, status} = System.cmd("sh", ["-c", script, "mix" | args], cd: dir, env: env)
      %{status: status, stdout: File.read!(stdout), stderr: File.read!(stderr)}
    after
      File.rm_rf!(io)
    end
  end

  @doc "`extra` environment variables, with the ones this suite's own run may leak unset."
  @spec env([{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def env(extra), do: for(var <- @leaky_env, do: {var, nil}) ++ extra

  @doc "Copies and compiles fixture `name`."
  @spec compiled!(String.t()) :: Path.t()
  def compiled!(name), do: name |> copy!() |> compile!()
end
