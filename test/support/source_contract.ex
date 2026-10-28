defmodule MixAffected.SourceContract do
  @moduledoc """
  The behaviour every `MixAffected.Graph.Source` adapter must show against the
  real fixture projects. `use MixAffected.SourceContract, source: Adapter, tags: [...]`
  defines the suite for that adapter; `tags` become module tags so a suite that
  needs a newer toolchain can be excluded as a whole.
  """

  defmacro __using__(opts) do
    source = Keyword.fetch!(opts, :source)
    tags = Keyword.get(opts, :tags, [])

    quote location: :keep do
      use ExUnit.Case, async: false

      alias MixAffected.FixtureProject
      alias MixAffected.Graph

      @source unquote(source)
      @moduletag unquote(tags)

      defp build(dir, opts \\ []), do: Graph.build(dir, Keyword.put(opts, :source, @source))

      defp affected(graph, changed) do
        {:ok, files} = Graph.dependents(graph, changed)
        Enum.sort(files)
      end

      setup_all do
        {:ok, single} = "single_app" |> FixtureProject.compiled!() |> build()

        {:ok, umbrella} =
          "umbrella"
          |> FixtureProject.compiled!()
          |> build(apps_paths: %{core: "apps/core", web: "apps/web"})

        %{single: single, umbrella: umbrella}
      end

      describe "single-app project" do
        test "records compile, export and runtime edge kinds", %{single: graph} do
          assert Graph.edge(graph, "lib/single_app/uses_macros.ex", "lib/single_app/macros.ex") ==
                   :compile

          assert Graph.edge(
                   graph,
                   "lib/single_app/requires_macros.ex",
                   "lib/single_app/macros.ex"
                 ) ==
                   :compile

          assert Graph.edge(graph, "lib/single_app/user_name.ex", "lib/single_app/user.ex") ==
                   :export

          assert Graph.edge(graph, "lib/single_app/direct.ex", "lib/single_app/leaf.ex") ==
                   :runtime
        end

        test "selects direct and transitive runtime dependents", %{single: graph} do
          assert affected(graph, ["lib/single_app/leaf.ex"]) == [
                   "lib/single_app/direct.ex",
                   "lib/single_app/leaf.ex",
                   "lib/single_app/transitive.ex"
                 ]
        end

        test "selects compile-time dependents through use and require", %{single: graph} do
          assert affected(graph, ["lib/single_app/macros.ex"]) == [
                   "lib/single_app/macros.ex",
                   "lib/single_app/requires_macros.ex",
                   "lib/single_app/uses_macros.ex"
                 ]
        end

        test "selects export dependents, including test/support compiled in the test env",
             %{single: graph} do
          assert affected(graph, ["lib/single_app/user.ex"]) == [
                   "lib/single_app/user.ex",
                   "lib/single_app/user_name.ex",
                   "test/support/user_factory.ex"
                 ]
        end

        test "terminates on a cycle and selects everything that reaches it", %{single: graph} do
          assert affected(graph, ["lib/single_app/pong.ex"]) == [
                   "lib/single_app/ping.ex",
                   "lib/single_app/pong.ex",
                   "lib/single_app/rally.ex"
                 ]
        end

        test "selects only the changed file when nothing depends on it", %{single: graph} do
          assert affected(graph, ["lib/single_app/standalone.ex"]) == [
                   "lib/single_app/standalone.ex"
                 ]
        end
      end

      describe "umbrella project" do
        test "records cross-app edges with their kinds under repo-relative paths", %{
          umbrella: graph
        } do
          assert Graph.edge(graph, "apps/web/lib/web/model.ex", "apps/core/lib/core/schema.ex") ==
                   :compile

          assert Graph.edge(
                   graph,
                   "apps/web/lib/web/account_view.ex",
                   "apps/core/lib/core/account.ex"
                 ) == :export

          assert Graph.edge(graph, "apps/web/lib/web/page.ex", "apps/web/lib/web/account_view.ex") ==
                   :runtime
        end

        test "selects transitive dependents across apps, including test/support",
             %{umbrella: graph} do
          assert affected(graph, ["apps/core/lib/core/account.ex"]) == [
                   "apps/core/lib/core/account.ex",
                   "apps/web/lib/web/account_view.ex",
                   "apps/web/lib/web/page.ex",
                   "apps/web/test/support/conn_case.ex"
                 ]
        end

        test "selects cross-app compile-time dependents", %{umbrella: graph} do
          assert affected(graph, ["apps/core/lib/core/schema.ex"]) == [
                   "apps/core/lib/core/schema.ex",
                   "apps/web/lib/web/model.ex"
                 ]
        end

        test "terminates on a cycle and selects its cross-app entrants", %{umbrella: graph} do
          assert affected(graph, ["apps/core/lib/core/odd.ex"]) == [
                   "apps/core/lib/core/even.ex",
                   "apps/core/lib/core/odd.ex",
                   "apps/web/lib/web/parity.ex"
                 ]
        end
      end

      describe "fails open" do
        test "when the project does not compile" do
          dir = FixtureProject.copy!("single_app")
          File.write!(Path.join(dir, "lib/single_app/leaf.ex"), "defmodule SingleApp.Leaf do\n")

          assert {:error, {:xref_failed, status, output}} = build(dir)
          assert status != 0
          assert output =~ "leaf.ex"
        end

        test "when the project has no compiled sources" do
          dir = FixtureProject.copy!("single_app")
          File.rm_rf!(Path.join(dir, "lib"))
          File.rm_rf!(Path.join(dir, "test/support"))

          assert build(dir) == {:error, :empty_graph}
        end
      end
    end
  end
end
