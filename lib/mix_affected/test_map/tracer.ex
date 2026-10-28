defmodule MixAffected.TestMap.Tracer do
  @moduledoc """
  Compiler tracer for `MixAffected.TestMap.Builder`. While test files are
  required, records in the `table/0` ETS bag:

    * `{{:ref, file}, module}` - `file` references `module` (remote or
      imported call or macro, alias reference, struct expansion, `require`,
      `import`)
    * `{{:def, module}, file}` - `file` defines `module`

  `file` is `env.file`, the file being compiled, so references injected by a
  macro (`use MyApp.DataCase`) count for the test file that expanded it.
  """

  @table :mix_affected_test_map_trace

  @doc "The ETS table the tracer writes to; it must exist while tracing."
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec trace(tuple() | atom(), Macro.Env.t()) :: :ok
  def trace({kind, _meta, module, _name, _arity}, env)
      when kind in [
             :remote_function,
             :remote_macro,
             :imported_function,
             :imported_macro,
             :imported_quoted
           ],
      do: ref(env, module)

  def trace({:alias_reference, _meta, module}, env), do: ref(env, module)
  def trace({:struct_expansion, _meta, module, _keys}, env), do: ref(env, module)

  def trace({kind, _meta, module, _opts}, env) when kind in [:require, :import],
    do: ref(env, module)

  def trace({:on_module, _bytecode, _ignore}, env) do
    :ets.insert(@table, {{:def, env.module}, env.file})
    :ok
  end

  def trace(_event, _env), do: :ok

  defp ref(env, module) when is_atom(module) do
    :ets.insert(@table, {{:ref, env.file}, module})
    :ok
  end
end
