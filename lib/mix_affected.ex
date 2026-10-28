defmodule MixAffected do
  @moduledoc """
  Nx-style "affected" selection for Elixir projects: given the source files a
  change touched, which files may now behave differently?

  The core is `MixAffected.Graph`: a file-level dependency graph of a
  compiled project, built by a `MixAffected.Graph.Source` adapter, with each
  edge labelled `:compile`, `:export` or `:runtime`.

      {:ok, graph} = MixAffected.Graph.build("/path/to/project")
      {:ok, files} = MixAffected.Graph.dependents(graph, ["lib/my_app/user.ex"])

  Selection is the reverse transitive closure over every edge kind: any
  dependency path from a file to a changed file means its behaviour may have
  changed. Anything the library cannot vouch for comes back as
  `{:error, reason}`; callers must treat every error as "run everything".
  """

  @doc """
  Loads every module of the library. Each task calls it first: installed as
  a Mix archive, the library's code path is one Mix's compile step deletes
  before compiling the project (it keeps only the project's own load paths),
  so a module first called after the compile would be undefined. For the
  same reason the tasks declare no `@requirements`: those run before the
  task, so a required compile would drop the library's code path first.
  """
  @spec load_modules!() :: :ok
  def load_modules! do
    case Application.load(:mix_affected) do
      :ok -> :ok
      {:error, {:already_loaded, :mix_affected}} -> :ok
    end

    {:ok, modules} = :application.get_key(:mix_affected, :modules)
    Code.ensure_all_loaded!(modules)
  end
end
