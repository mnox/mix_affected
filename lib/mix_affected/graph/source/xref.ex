defmodule MixAffected.Graph.Source.Xref do
  @moduledoc false
  # Runs `mix` in another project. Mix env vars that would point the child at
  # this VM's build or deps (or another mix.exs) are cleared.

  @leaky_env ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_EXS MIX_LOCKFILE)

  @spec graph(Path.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, MixAffected.Graph.error()}
  def graph(root, format, opts) do
    tmp = Path.join(System.tmp_dir!(), "mix_affected_xref_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    output = Path.join(tmp, "graph.#{format}")

    try do
      with {:ok, _log} <-
             mix(root, ["xref", "graph", "--format", format, "--output", output], opts) do
        read(output)
      end
    after
      File.rm_rf(tmp)
    end
  end

  @spec mix(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, MixAffected.Graph.error()}
  def mix(root, args, opts) do
    case Keyword.get_lazy(opts, :mix_executable, fn -> System.find_executable("mix") end) do
      nil ->
        {:error, :mix_not_found}

      mix ->
        env = [
          {"MIX_ENV", Keyword.get(opts, :mix_env, "test")} | Enum.map(@leaky_env, &{&1, nil})
        ]

        case System.cmd(mix, args, cd: root, env: env, stderr_to_stdout: true) do
          {log, 0} -> {:ok, log}
          {log, status} -> {:error, {:xref_failed, status, log}}
        end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, posix} -> {:error, {:output_unreadable, posix}}
    end
  end
end
