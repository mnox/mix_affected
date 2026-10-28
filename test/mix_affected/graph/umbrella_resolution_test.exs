defmodule MixAffected.Graph.UmbrellaResolutionTest do
  # xref prints umbrella-root paths relative to each child app. These prove
  # that MixAffected fails open whenever it cannot map them back to one file.
  use ExUnit.Case, async: false

  alias MixAffected.FixtureProject
  alias MixAffected.Graph

  @apps_paths %{core: "apps/core", web: "apps/web"}

  test "an umbrella built without its apps_paths fails open with the unresolved paths" do
    dir = FixtureProject.compiled!("umbrella")

    assert {:error, {:unresolved_paths, paths}} = Graph.build(dir)
    assert "lib/core/account.ex" in paths
    assert "test/support/conn_case.ex" in paths
  end

  test "two apps sharing a relative source path fail open instead of losing edges" do
    dir = FixtureProject.copy!("umbrella")

    File.mkdir_p!(Path.join(dir, "apps/core/test/support"))

    File.write!(Path.join(dir, "apps/core/test/support/conn_case.ex"), """
    defmodule Core.ConnCase do
      def account, do: %Core.Account{name: "core"}
    end
    """)

    FixtureProject.compile!(dir)

    assert Graph.build(dir, apps_paths: @apps_paths) ==
             {:error, {:ambiguous_paths, ["test/support/conn_case.ex"]}}
  end
end
