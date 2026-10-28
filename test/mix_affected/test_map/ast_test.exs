defmodule MixAffected.TestMap.AstTest do
  use ExUnit.Case, async: true

  alias MixAffected.TestMap.Ast

  test "references resolves alias forms used in the file" do
    source = """
    defmodule MyApp.UserTest do
      use MyApp.DataCase
      alias MyApp.Accounts
      alias MyApp.Billing.Invoice, as: Bill
      alias MyApp.Web.{Endpoint, Router}

      test "x" do
        Accounts.get(1)
        Bill.new()
        Endpoint.url() <> Router.path()
        :ets.new(:t, [])
      end
    end
    """

    assert {:ok, modules} = Ast.references(source)

    for module <- [
          MyApp.DataCase,
          MyApp.Accounts,
          MyApp.Billing.Invoice,
          MyApp.Web.Endpoint,
          MyApp.Web.Router,
          MyApp.UserTest
        ] do
      assert module in modules, "expected #{inspect(module)} in #{inspect(modules)}"
    end
  end

  test "references fails on a file that does not parse" do
    assert Ast.references("defmodule Broken do\n") == :error
  end

  test "affected_by reads literal @affected_by glob lists only" do
    source = """
    defmodule MyApp.ClientTest do
      use ExUnit.Case
      @affected_by ["lib/my_app/clients/**", "priv/fixtures/*.json"]
      @affected_by some_function()
      @other ["lib/no/**"]
    end
    """

    assert Ast.affected_by(source) == ["lib/my_app/clients/**", "priv/fixtures/*.json"]
    assert Ast.affected_by("defmodule Broken do\n") == []
  end

  test "affected_by reads @moduletag affected_by:, alone or among other tags" do
    source = """
    defmodule MyApp.ClientTest do
      use ExUnit.Case
      @moduletag affected_by: ["lib/my_app/clients/**"]
      @moduletag :integration
      @moduletag timeout: 5_000, affected_by: ["priv/fixtures/*.json"]
      @moduletag [:slow, affected_by: ["lib/my_app/slow.ex"]]
      @moduletag affected_by: some_function()
      @moduletag other: ["lib/no/**"]
    end
    """

    assert Ast.affected_by(source) ==
             ["lib/my_app/clients/**", "priv/fixtures/*.json", "lib/my_app/slow.ex"]
  end

  describe "reads" do
    @top ["Dockerfile", "guides", "lib", "priv", "test"]

    defp reads(source, test \\ "test/my_app/guard_test.exs"), do: Ast.reads(source, test, @top)

    test "a source-scanning guard reads the roots it names, as files or dirs" do
      # A guard test that scans whole source roots for a forbidden pattern.
      source = ~S"""
      defmodule MyApp.GuardTest do
        use ExUnit.Case, async: true
        @roots ["lib/my_app", "lib/my_app_web"]
        @allowed MapSet.new(["lib/my_app/allowed.ex"])
        @banned ~r/metadata\["origin"\]|lib\/nope/

        test "no raw access" do
          violations =
            @roots
            |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs}")))
            |> Enum.reject(&MapSet.member?(@allowed, &1))
            |> Enum.filter(&(File.read!(&1) =~ @banned))

          assert violations == []
        end
      end
      """

      assert reads(source) == [
               "lib/my_app",
               "lib/my_app/**",
               "lib/my_app/allowed.ex",
               "lib/my_app/allowed.ex/**",
               "lib/my_app_web",
               "lib/my_app_web/**"
             ]
    end

    test "a test that reads no files reads nothing, whatever path literals it holds" do
      source = """
      defmodule MyApp.PathTest do
        use ExUnit.Case
        test "x", do: assert(MyApp.path() == "lib/my_app/x.ex")
      end
      """

      assert reads(source) == []
    end

    test "literal globs are kept and joined Path.join literals read as one path" do
      source = """
      defmodule MyApp.DocsTest do
        use ExUnit.Case
        test "x" do
          Path.wildcard("guides/*.md")
          File.read!(Path.join("lib", "my_app/x.ex"))
          File.read!(Path.join(["priv", "repo", name()]))
          File.exists?("Dockerfile")
        end
      end
      """

      assert reads(source) == [
               "Dockerfile",
               "Dockerfile/**",
               "guides/*.md",
               "lib/my_app/x.ex",
               "lib/my_app/x.ex/**",
               "priv/repo",
               "priv/repo/**"
             ]
    end

    test "__DIR__-relative paths resolve against the test file's directory" do
      source = """
      defmodule MyApp.ValuesTest do
        use ExUnit.Case
        @values Path.expand("../../guides/topology.md", __DIR__)
        @docker Path.join(__DIR__, "../../Dockerfile")
        @root Path.expand("../..", __DIR__)
        test "x", do: File.read!(@values) <> File.read!(@docker) <> @root
      end
      """

      assert reads(source) == [
               "Dockerfile",
               "Dockerfile/**",
               "guides/topology.md",
               "guides/topology.md/**"
             ]
    end

    test "a path escaping the root, an unanchored or cwd read, or no resolvable path reads everything" do
      for body <- [
            ~S|File.read!(Path.expand("../../../../outside.txt", __DIR__))|,
            ~S|Path.wildcard("**/*.ex")|,
            ~S|File.ls!(".")|,
            ~S|File.ls!(File.cwd!())|,
            ~S|File.read!(path_from_somewhere())|
          ] do
        source = "defmodule T do
  test \"x\", do: #{body}
end
"
        assert reads(source) == ["**"], body
      end
    end

    test "interpolated suffixes, ~w words and the priv dir anchor reads" do
      source = ~S"""
      defmodule MyApp.MixedTest do
        use ExUnit.Case
        @files ~w(lib/my_app/a.ex lib/my_app/b.ex)
        test "x" do
          File.read!("#{File.cwd!()}/guides/x.md")
          File.read!(Path.join(:code.priv_dir(:my_app), "code_index/corpus.json"))
          Enum.map(@files, &File.read!/1)
        end
      end
      """

      globs = reads(source)

      for path <- ~w(guides/x.md lib/my_app/a.ex lib/my_app/b.ex priv/code_index/corpus.json),
          do: assert(MixAffected.Glob.find(globs, path), "#{path} not in #{inspect(globs)}")

      refute MixAffected.Glob.find(globs, "lib/my_app/c.ex")
    end

    test "an unparseable file reads everything" do
      assert reads("defmodule Broken do\n") == ["**"]
    end
  end
end
