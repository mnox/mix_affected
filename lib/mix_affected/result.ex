defmodule MixAffected.Result do
  @moduledoc """
  The answer of `mix affected.files` / `mix affected.test`, and its v1 JSON
  and text renderings (see the README for the schema).

  `exit_status` is `0` for any answer, `2` when the graph or the test map
  could not be built: the result is then a full run.
  """

  @type t :: %__MODULE__{
          full_run: boolean(),
          reason: String.t() | nil,
          changed_files: [String.t()],
          affected_files: [String.t()],
          tests: [String.t()],
          total_test_files: non_neg_integer(),
          graph_source: String.t(),
          explain: %{optional(String.t()) => [String.t()]},
          exit_status: 0 | 2
        }

  defstruct full_run: false,
            reason: nil,
            changed_files: [],
            affected_files: [],
            tests: [],
            total_test_files: 0,
            graph_source: nil,
            explain: %{},
            exit_status: 0

  @doc "Marks `result` as a full run for `reason`; `tests`, `affected_files` and `explain` are cleared."
  @spec full_run(t(), String.t(), 0 | 2) :: t()
  def full_run(%__MODULE__{} = result, reason, exit_status \\ 0),
    do: %{
      result
      | full_run: true,
        reason: reason,
        tests: [],
        affected_files: [],
        explain: %{},
        exit_status: exit_status
    }

  @doc "The v1 JSON document. `explain` is `%{}` unless `explain?`."
  @spec to_json(t(), boolean()) :: String.t()
  def to_json(%__MODULE__{} = r, explain?) do
    JSON.encode!(%{
      schema_version: 1,
      full_run: r.full_run,
      reason: r.reason,
      changed_files: r.changed_files,
      affected_files: r.affected_files,
      tests: r.tests,
      total_test_files: r.total_test_files,
      graph_source: r.graph_source,
      explain: if(explain?, do: r.explain, else: %{})
    })
  end

  @doc """
  Text output: one test file per line (with `explain?`, one chain per line,
  `changed -> ... -> test`). A full run prints nothing; its reason goes to
  stderr (see `summary/1`).
  """
  @spec to_text(t(), boolean()) :: String.t()
  def to_text(%__MODULE__{full_run: true}, _explain?), do: ""

  def to_text(%__MODULE__{tests: tests, explain: explain}, explain?) do
    Enum.map_join(tests, fn test ->
      if explain?,
        do: Enum.join(Map.get(explain, test, [test]), " -> ") <> "\n",
        else: test <> "\n"
    end)
  end

  @doc "A one-line human summary for stderr."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{full_run: true, reason: reason}),
    do: "mix_affected: full run (#{reason})"

  def summary(%__MODULE__{tests: [], changed_files: changed}),
    do: "mix_affected: no affected tests (#{length(changed)} changed files)"

  def summary(%__MODULE__{tests: tests, total_test_files: total}),
    do: "mix_affected: #{length(tests)} of #{total} test files affected"
end
