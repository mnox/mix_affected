defmodule MixAffected.ArchiveIntegrationTest do
  # The tasks installed as a Mix archive in a project that does not depend on
  # the library, as a CI pipeline installs them. Before compiling the project,
  # Mix's compile.all deletes every code path it did not load for the project,
  # the archive's included, so a module of ours first called after the
  # compile is undefined unless the task loaded it before.
  use ExUnit.Case, async: false

  alias MixAffected.FixtureProject

  @repo Path.expand("../..", __DIR__)

  setup_all do
    tmp = Path.join(System.tmp_dir!(), "mix_affected_ez_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    archives = Path.join(tmp, "archives")
    ez = Path.join(tmp, "mix_affected.ez")
    src = Path.join(tmp, "src")

    # Built from a copy so this suite's _build is never touched.
    File.mkdir_p!(src)

    for entry <- ~w(lib mix.exs .tool-versions),
        do: File.cp_r!(Path.join(@repo, entry), Path.join(src, entry))

    mix!(src, ["archive.build", "-o", ez], [{"MIX_ENV", "prod"}])
    mix!(src, ["archive.install", ez, "--force"], [{"MIX_ARCHIVES", archives}])

    dir = FixtureProject.copy!("single_app")
    mix_exs = Path.join(dir, "mix.exs")
    File.write!(mix_exs, String.replace(File.read!(mix_exs), "deps: deps(),", "deps: [],"))
    %{dir: dir, env: [{"MIX_ARCHIVES", archives}]}
  end

  defp mix!(dir, args, env) do
    case System.cmd("mix", args, cd: dir, env: FixtureProject.env(env), stderr_to_stdout: true) do
      {_log, 0} -> :ok
      {log, status} -> flunk("mix #{Enum.join(args, " ")} exited #{status}: #{log}")
    end
  end

  test "affected.files builds the map and selects with the tasks from an archive", %{
    dir: dir,
    env: env
  } do
    assert File.read!(Path.join(dir, "mix.exs")) =~ "deps: [],"

    result =
      FixtureProject.mix(dir, ["affected.files", "--files", "-"],
        stdin: "lib/single_app/leaf.ex\n",
        env: env
      )

    assert result.status == 0, result.stderr

    assert result.stdout ==
             """
             test/single_app/direct_test.exs
             test/single_app/leaf_test.exs
             test/single_app/transitive_test.exs
             """
  end
end
