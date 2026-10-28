defmodule MixAffected.CLI do
  @moduledoc false
  # Shared plumbing of the affected.* Mix tasks: option parsing, the selection
  # run against the current Mix project, output and exit codes
  # (0 ok, 1 usage, 2 internal failure -> the output says full_run).

  alias MixAffected.ChangedFiles
  alias MixAffected.Config
  alias MixAffected.Result
  alias MixAffected.Run
  alias MixAffected.TestMap

  @select_switches [
    base: :string,
    files: :string,
    format: :string,
    explain: :boolean,
    output: :string,
    map: :string
  ]

  @type select_opts :: %{
          source: {:base, String.t()} | {:files, String.t()},
          format: :text | :json,
          explain: boolean(),
          output: Path.t() | nil,
          map: Path.t() | nil
        }

  @doc "Splits `args` at the first `--` into own args and passthrough."
  @spec split_passthrough([String.t()]) :: {[String.t()], [String.t()]}
  def split_passthrough(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {own, ["--" | rest]} -> {own, rest}
      {own, []} -> {own, []}
    end
  end

  @doc "Parses affected.files / affected.test options."
  @spec parse_select([String.t()]) :: {:ok, select_opts()} | {:error, String.t()}
  def parse_select(args) do
    with {:ok, opts} <- strict(args, @select_switches),
         {:ok, source} <- source(opts),
         {:ok, format} <- format(opts) do
      {:ok,
       %{
         source: source,
         format: format,
         explain: Keyword.get(opts, :explain, false),
         output: opts[:output],
         map: opts[:map]
       }}
    end
  end

  @doc "Parses affected.report options."
  @spec parse_report([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_report(args) do
    with {:ok, opts} <- strict(args, selection: :string, format: :string, output: :string),
         {:ok, format} <- format(opts) do
      case opts[:selection] do
        nil -> {:error, "--selection <selection.json> is required"}
        selection -> {:ok, %{selection: selection, format: format, output: opts[:output]}}
      end
    end
  end

  @doc "Parses affected.map options."
  @spec parse_map([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_map(args) do
    with {:ok, opts} <- strict(args, map: :string), do: {:ok, %{map: opts[:map]}}
  end

  @doc "Runs the selection for the current Mix project, or fails with a usage error."
  @spec select!(select_opts()) :: Result.t()
  def select!(opts) do
    warn_env()
    root = File.cwd!()
    config = config!()
    changed = changed!(root, opts.source)

    if Mix.Project.umbrella?() do
      Result.full_run(
        %Result{changed_files: changed, graph_source: "none"},
        "test_map_unavailable:umbrella_not_supported"
      )
    else
      Run.run(changed, Run.defaults(root, config, map_path(opts.map)))
    end
  end

  @doc "The test map path: `--map` or `_build/<env>/mix_affected/test_map.etf`."
  @spec map_path(Path.t() | nil) :: Path.t()
  def map_path(nil), do: TestMap.default_path(Mix.Project.build_path())
  def map_path(path), do: Path.expand(path)

  @doc "The project config, or a usage error."
  @spec config!() :: Config.t()
  def config! do
    case Config.from_project(Mix.Project.config()) do
      {:ok, config} -> config
      {:error, message} -> usage_error!(message)
    end
  end

  @doc "Renders `result`, writes it to `--output` or stdout and the summary to stderr."
  @spec emit(Result.t(), select_opts()) :: :ok
  def emit(result, opts) do
    body =
      case opts.format do
        :json -> Result.to_json(result, opts.explain) <> "\n"
        :text -> Result.to_text(result, opts.explain)
      end

    write(body, opts.output)
    IO.puts(:stderr, Result.summary(result))
  end

  @doc "Writes `body` to `output` (a path) or stdout (`nil`)."
  @spec write(String.t(), Path.t() | nil) :: :ok
  def write(body, nil), do: IO.write(body)

  def write(body, output) do
    File.mkdir_p!(Path.dirname(Path.expand(output)))
    File.write!(output, body)
  end

  @doc "Exits with `result`'s exit status when it is not 0."
  @spec halt_on_failure(Result.t()) :: :ok
  def halt_on_failure(%Result{exit_status: 0}), do: :ok
  def halt_on_failure(%Result{exit_status: status}), do: exit({:shutdown, status})

  @doc "Prints `message` and exits 1."
  @spec usage_error!(String.t()) :: no_return()
  def usage_error!(message) do
    Mix.shell().error("mix_affected: #{message}")
    exit({:shutdown, 1})
  end

  defp warn_env do
    if Mix.env() != :test do
      IO.puts(:stderr, "mix_affected: warning: run with MIX_ENV=test (current: #{Mix.env()})")
    end
  end

  defp changed!(root, source) do
    result =
      case source do
        {:base, ref} -> ChangedFiles.from_git(root, ref)
        {:files, path} -> ChangedFiles.from_files(path)
      end

    case result do
      {:ok, files} -> files
      {:error, message} -> usage_error!(message)
    end
  end

  defp strict(args, switches) do
    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, [arg | _], []} -> {:error, "unexpected argument #{inspect(arg)}"}
      {_opts, _args, [{flag, _} | _]} -> {:error, "invalid option #{flag}"}
    end
  end

  defp source(opts) do
    case {opts[:base], opts[:files]} do
      {nil, nil} -> {:error, "give exactly one of --base <git-ref> or --files <path|->"}
      {base, nil} -> {:ok, {:base, base}}
      {nil, files} -> {:ok, {:files, files}}
      {_, _} -> {:error, "--base and --files are mutually exclusive"}
    end
  end

  defp format(opts) do
    case Keyword.get(opts, :format, "text") do
      "text" -> {:ok, :text}
      "json" -> {:ok, :json}
      other -> {:error, "--format must be text or json, got #{inspect(other)}"}
    end
  end
end
