# MixAffected

[![CI](https://github.com/mnox/mix_affected/actions/workflows/ci.yml/badge.svg)](https://github.com/mnox/mix_affected/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/mix_affected.svg)](https://hex.pm/packages/mix_affected)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/mix_affected)

Run only the tests a change can affect. Given the files a change touched,
`mix_affected` works out which test files must run, in the spirit of Nx's
`affected` command and Bazel's test selection, for plain Mix projects.

    $ mix affected.files --base origin/main
    test/my_app/accounts_test.exs
    test/my_app_web/user_controller_test.exs

    $ mix affected.test --base origin/main -- --warnings-as-errors

Anything the library cannot vouch for is a **full run**, never an empty or
partial selection.

## Contents

* [How it works](#how-it-works)
* [Requirements](#requirements)
* [Install](#install)
* [Adopting it safely](#adopting-it-safely)
* [CI usage](#ci-usage)
* [Tasks](#tasks)
* [Configuration](#configuration)
* [How selection works](#how-selection-works)
* [Escape hatches](#escape-hatches)
* [Limitations](#limitations)
* [Contributing](#contributing)
* [License](#license)

## How it works

1. **Change set.** The files changed since a git ref (`--base`), or a list
   you pass in (`--files`), for CI containers without `.git`.
2. **Dependency graph.** `mix xref graph` of your project in the test env,
   read through an adapter: JSON on Elixir 1.19+, DOT before. Every changed
   source plus everything that reaches it through compile, export or runtime
   edges is *affected*.
3. **Test map.** Which source files each test file references. It is built
   by requiring every test file with a compiler tracer registered, so it sees
   what the compiler sees, including code injected by `use` and macros. No
   test runs. The map also records which repository files a test reads
   (`File.read!`, `Path.wildcard`, `@external_resource`, ...).
4. **Selection.** A test runs when it changed, when it references an
   affected file, when it reads a changed file, or when your config or a
   `@moduletag affected_by:` says so.
5. **Fail open.** A changed config file, a file the graph does not compile
   (`.heex`, `.po`, a deleted module), a graph or map that cannot be built, or
   a map entry that is out of date: each is a full run with a reason.

## Requirements

* Elixir 1.18 or later (the JSON graph adapter needs 1.19 or later; 1.18
  uses the DOT adapter) and OTP 25 or later. CI covers Elixir 1.18 to 1.20.
* A single-app Mix project. Umbrella projects are not supported yet (an
  umbrella root is always a full run).
* `git` on the path, for `--base` only.
* Linux or macOS. Windows is not supported yet: path handling there
  (drive letters, `__DIR__` paths) is known to be incomplete.

## Install

Add the dependency and run the tasks in the test env:

```elixir
# mix.exs
def project do
  [
    # ...
    deps: deps()
  ]
end

# The tasks must run in the test env.
def cli do
  [
    preferred_envs: [
      "affected.files": :test,
      "affected.test": :test,
      "affected.map": :test,
      "affected.report": :test
    ]
  ]
end

defp deps do
  [
    {:mix_affected, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Without `preferred_envs`, run the tasks with `MIX_ENV=test`
(`affected.files` and `affected.test` warn otherwise). The test env matters: `test/support` is compiled only there and
must be part of the dependency graph.

### As a Mix archive

To try it in a project without touching its `mix.exs`, build and install it
as an archive with the project's Elixir/OTP versions:

```sh
git clone https://github.com/mnox/mix_affected.git && cd mix_affected
MIX_ENV=prod mix archive.build -o mix_affected.ez && mix archive.install mix_affected.ez --force
```

Before compiling a project, Mix deletes the code paths it did not load for
it, archives included, so each task loads all of the library's modules
first.

## Adopting it safely

Before trusting a selection to gate merges, run it in *shadow mode*: keep
running the full suite, save the selection next to it, and check what it
would have missed.

```sh
mix affected.files --base origin/main --format json --output selection.json
mix test   # the full suite, as before
mix affected.report --selection selection.json
```

`mix affected.report` prints the failed test files the selection did not
include. Once that stays empty, switch the job to `mix affected.test`.

## CI usage

With a full checkout, `--base` is enough:

```sh
MIX_ENV=test mix affected.test --base "origin/$BASE" -- --warnings-as-errors
```

`--base` diffs against the merge base, so fetch enough history for it
(for example `fetch-depth: 0` with `actions/checkout`). With no merge base
(a shallow clone missing it, or unrelated histories) the task exits 1 with
git's `no merge base` error rather than selecting nothing. So does an empty
`--base`, or one like `origin/` left by an unset `$GITHUB_BASE_REF` on a push
event.

If the test container has no `.git` (a Docker build context, say), compute
the change set on the runner and pass it in:

```sh
# on the runner, with the repo checked out
git diff --name-only --no-renames "origin/$BASE...HEAD" > changed.txt

# in the test container
MIX_ENV=test mix affected.files --files changed.txt --format json --output selection.json
MIX_ENV=test mix affected.test --files changed.txt -- --warnings-as-errors
```

Mix tasks may read stdin even with `--files <path>`, so inside a shell loop
redirect it (`mix affected.files --files changed.txt </dev/null`): otherwise a
`while read` loop silently stops after its first iteration.

## Tasks

| Task | Purpose |
|---|---|
| `mix affected.files` | Print the affected test files for a change set. |
| `mix affected.test` | Run `mix test` on the selection (or the whole suite on a full run). |
| `mix affected.map` | Build the test map (test file -> referenced source files). The two tasks above build it when it is missing. |
| `mix affected.report` | After a full `mix test`, list failed test files a saved selection missed. |

### Input (`affected.files`, `affected.test`)

Exactly one of:

* `--base <git-ref>`: the union of `git diff --name-only --no-renames
  <ref>...HEAD`, uncommitted changes (`git diff --name-only --no-renames
  HEAD`) and untracked files (`git ls-files --others --exclude-standard`),
  all repository-wide (`--no-relative` overrides a `diff.relative` config;
  untracked files are listed from the top level), so a project in a
  subdirectory still sees changes beside it.
  `--no-renames` makes a moved file appear as delete + add, so its old path
  forces a full run. The ref must resolve to a commit (`git rev-parse
  --verify <ref>^{commit}`) and is checked before any diff: an empty or
  blank ref, a ref starting with `-`, or one that is not a commit is a usage
  error (exit 1). It also needs a merge base with `HEAD`.
* `--files <path|->`: newline-separated project-relative paths; `-` reads
  stdin. No git needed.

Options:

* `--format text|json`: text (default) prints one test path per line. On a
  full run it prints nothing on stdout and the reason on stderr.
* `--explain`: the dependency chain per selected test. Text mode prints one
  `changed file -> ... -> test` line per test instead of the bare path; JSON
  fills `explain`.
* `--output <path>`: write the output to a file instead of stdout.
* `--map <path>`: use the test map at `<path>`, building it there if it is
  missing or in an older format (default
  `_build/test/mix_affected/test_map.etf`). A prebuilt map whose entry
  for a selected test is stale is a full run (see **Map freshness**).

A one-line summary always goes to stderr. Mix may print compile output on
stdout when the project is stale, so CI should prefer `--output`.


### `affected.test`

Everything after `--` goes to `mix test` unchanged.

* full run (including a graph or test map failure): `mix test <passthrough>`
* empty selection: prints `mix_affected: no affected tests`, exits 0, never
  starts ExUnit
* otherwise: `mix test <files> <passthrough>`, exiting with its status

With `--output <path>` it also writes the selection there (in `--format`),
for `affected.report`.

### JSON (`--format json`)

```json
{
  "schema_version": 1,
  "full_run": false,
  "reason": null,
  "changed_files": ["lib/app/foo.ex"],
  "affected_files": ["lib/app/foo.ex", "lib/app/bar.ex"],
  "tests": ["test/app/foo_test.exs"],
  "total_test_files": 1456,
  "graph_source": "xref_json | xref_dot | none",
  "explain": {"test/app/foo_test.exs": ["lib/app/foo.ex", "test/app/foo_test.exs"]}
}
```

* `full_run: true` means "run the whole suite". `reason` then starts with
  `global_invalidation:<glob>:<file>`, `unmapped_file:<file>`,
  `graph_unavailable:<detail>` or `test_map_unavailable:<detail>`, and
  `tests` and `affected_files` are `[]`.
* `changed_files` is the normalized change set (ignored files included);
  `affected_files` is the graph closure of the changed sources plus the
  changed test files.
* `graph_source` names the graph adapter configured for the run
  (`xref_json` on Elixir >= 1.19, `xref_dot` before), even when no source
  changed and the graph was not built. It is `none` when no adapter applies:
  at an umbrella root, which is always a full run.
* `explain` is `{}` unless `--explain`. Tests selected because the map
  cannot vouch for them have the one-element chain `[test]`.
* An empty selection (`full_run: false`, `tests: []`) is valid: nothing is
  affected.

### Exit codes (`affected.files`)

| Code | Meaning | CI handling |
|---|---|---|
| 0 | Success, including a full run (an umbrella root is always one) and an empty selection. | Use the output. |
| 1 | Usage error: bad flags, missing or unreadable input, a `--base` that is empty, starts with `-`, is not a commit or has no merge base with `HEAD`, invalid `affected:` config (including a malformed glob, a glob not in normal form or a pattern naming a directory), or a `:test_paths`/`:test_pattern` that does not compile as a glob. | Fail the step. |
| 2 | Internal failure: the graph or the test map could not be built, or a prebuilt map entry is stale (`test_map_unavailable:stale_entry:<test>`). The output says `full_run: true`. | Treat as a full run. |

`affected.test` never exits 2: on any full run it runs the whole suite and
exits with `mix test`'s status, or 1 on a usage error.

### `affected.report`

```sh
mix affected.files --files changed.txt --format json --output selection.json
mix test   # the full suite
mix affected.report --selection selection.json --format json
```

```json
{
  "schema_version": 1,
  "selection_full_run": false,
  "failed_files": ["test/app/bar_test.exs"],
  "missed_files": ["test/app/bar_test.exs"],
  "selected_count": 12,
  "total_test_files": 1456
}
```

`missed_files` are failed test files that were not in the selection
(always `[]` for a full-run selection). Text mode prints the missed files.
It always exits 0 (a miss is data, not a failure), except for a usage error
such as a missing or unreadable `--selection`.

It reads ExUnit's failures manifest, the file `mix test --failed` uses:
`Path.join(Mix.Project.manifest_path(), ".mix_test_failures")`, or
`config :ex_unit, failures_manifest_path:` when set. The file holds
`:erlang.term_to_binary({1, %{{module, test_name} => test_file}})`, or
`{1, :all}` when the run crashed (same in Elixir 1.18 and 1.19). A missing
manifest, a crashed run, or any other format is reported as
`failed_files: []` with a warning on stderr. The manifest accumulates across
runs (passing tests are removed, unrun failures stay), so read it after a
full run.


## Configuration

In the consuming project's `project/0`:

```elixir
affected: [
  # replaces the defaults below when given
  global_invalidation: ["config/**", "mix.exs", "mix.lock", "test/test_helper.exs",
                        "priv/repo/migrations/**"],
  # extra globs appended to global_invalidation
  extra_global_invalidation: [],
  # changed files that affect no test (dropped first); default ["*.md", "docs/**/*.md"]
  # (root and docs/ markdown only: other .md may be runtime data, so it is unmapped)
  ignore: ["*.md", "docs/**/*.md"],
  # source glob => test globs that must run when a matching file is affected
  mappings: [{"lib/app/workers/**", ["test/app/workers/**"]}]
]
```

Globs match project-root-relative paths: `**` spans directories (`**/` also
matches none), `*` and `?` stay within one, `{a,b}` is alternation. Every
other character is literal, and a glob matches the whole path, so a pattern
with no `*`, `?` or `{` matches exactly one file.
Unknown keys or malformed values are a usage error (exit 1), not silently
ignored. That includes, in any key:

* a glob that does not compile: an unclosed `{` (`"lib/{a,b"`) or a `}` with
  no `{` before it
* a pattern naming a directory: any glob ending in `/` (`"lib/app/workers/"`,
  `"lib/app/workers/**/"`, since a changed path never ends in `/`), or a
  glob-free pattern that is a directory under the project root
  (`"lib/app/workers"`): it would match no file under it. The error names
  the fix, `"lib/app/workers/**"` (`"**"` for `"./"`).
* a glob not in normal form: a `.`, `..` or empty segment
  (`"lib/./app/**"`, `"lib//app/**"`, `"lib/../lib/app/**"`). Changed paths
  are normalized, so such a glob would match nothing; the error names the
  normal form. A leading `./` is fine; a glob whose `..` climbs above the
  project root is an error.
* bytes that are not valid UTF-8

`:test_paths` and `:test_pattern` are checked the same way: a pattern that
does not compile is a usage error rather than a crash during selection.

A test module can declare the files it depends on in ways no compiler sees:

```elixir
defmodule MyApp.ClientTest do
  use ExUnit.Case
  @moduletag affected_by: ["lib/my_app/clients/**"]
end
```

The tag may share its keyword list with other tags
(`@moduletag integration: true, affected_by: [...]`). The attribute form
works too, but needs registering so it does not warn as unused (which
would fail `mix test --warnings-as-errors`):

```elixir
Module.register_attribute(__MODULE__, :affected_by, persist: true)
@affected_by ["lib/my_app/clients/**"]
```

Either way only a literal list of strings is read (from the file's AST).
Its globs follow the config rules above, but a bad one never stops the
build: `mix affected.map` drops it, marks that test file `:always` (it runs
whenever anything is affected) and warns on stderr, for example
`mix_affected: warning: test/my_app/client_test.exs: affected_by glob
"lib/my_app/clients" names a directory, so it matches no file; write
"lib/my_app/clients/**" to match the files under it; it always runs`.
`affected.files` and `affected.test` pass that warning on when they build
the map. Other test files are unaffected.


## How selection works

Each changed file gets the first rule that applies:

1. matches `ignore`: dropped, except that it still selects the tests that
   read it from the repo (see **Tests that read the repo**)
2. matches `global_invalidation`: full run, `global_invalidation:<glob>:<file>`
3. a test file (under `:test_paths`, matching `:test_pattern`): selected
   directly
4. a compiled source in the graph: seeds the dependency closure
5. anything else (a deleted lib file, `.heex`, `.po`, other external
   resources, any file the graph does not compile): full run,
   `unmapped_file:<file>`

Any seed (a changed source, a changed or deleted test file) also selects
every test whose map entry has unresolved modules: the changed file may have
defined them, and a map built after the change no longer points at it.

### Tests that read the repo

Some tests read project files themselves instead of calling the code: a
guard that scans `lib/**` with `Path.wildcard` and `File.read!` for a banned
pattern, a test checking `guides/*.md` or the `Dockerfile`. They reference no
module of what they read, so the graph never reaches them. The map records,
per test file, the globs of what it reads (`reads`), from its AST:

* only a test calling a file-reading or -listing function (`File.read/1`,
  `File.read!/1`, `File.stream!/1`, `File.ls/1`, `File.exists?/1`,
  `Path.wildcard/1`, `:file.read_file/1`, `Code.eval_file/1`, ...) or
  declaring `@external_resource` reads anything
* every string literal in such a file whose first segment is an entry of the
  project root is a read path: `"lib/app"` reads `lib/app` and `lib/app/**`,
  `"guides/*.md"` stays a glob. `Path.join` of leading literals is one path;
  `Path.expand(path, __DIR__)` and `Path.join(__DIR__, path)` resolve against
  the test's directory; `:code.priv_dir/1` is `priv`; `~w` words and the
  literal parts of an interpolation count; regexes do not
* `reads` is `["**"]` (it may read anything) when that cannot be pinned
  down: the file does not parse, it reads but no literal names a repo path,
  a reading call's literal argument is not anchored at the root (`"."`,
  `"**/*.ex"`, `"fixtures/x.json"`), it lists the working directory, a
  `__DIR__` path leaves the root, or a literal glob is malformed or uses a
  `[...]` character class (which these globs do not implement)

A test whose `reads` match a *changed* file (a seed: a changed source or
test file, or an ignored file) is selected. A file merely reached through
the graph does not count: its content did not change. Ignoring is about
dependents, not readers, so an ignored file a test reads still selects that
test (fail open), and a change of only ignored files reads the map to find
them. A changed file the graph does not compile is still a full run
(`unmapped_file:`): `reads` never narrows a full run.

`test/support/**` is not a global invalidation: it is compiled in the test
env, so it is in the graph like any source.

The **graph** is `mix xref graph` of the project in the test env
(`MixAffected.Graph`): every changed source plus everything that reaches it
through compile, export or runtime edges is affected.

The **test map** says which source files each test file references. A test
file is selected when it changed, when a module it references lives in an
affected file, when one of its `affected_by` globs (tag or attribute)
matches an affected file, or when a `mappings` entry's source glob matches
an affected file and one of its test globs matches the test. Test files can
define modules too:
a test referencing one is selected when that test file is affected, and a
selected test also selects the test files defining modules it uses (so
`mix test <files>` can load it). `--explain` reconstructs one shortest chain.

### Building the test map: which path and why

`mix affected.map` (run in the consuming project's VM, test env) compiles
the project, starts it as `mix test` does, calls `ExUnit.start(autorun:
false)`, requires each `test_helper.exs`, then requires every test file with a
compiler tracer registered through `Code.put_compiler_option(:tracers, ...)`.
No test runs. Per test file the tracer records every referenced module
(remote and imported calls and macros, alias references, struct expansions,
`require`, `import`, including code injected by `use`), and every module the
file defines. Modules map to files through the defining test file, else
`module.module_info(:compile)[:source]`; sources in deps, `_build` or outside
the project are dropped.

This is the primary path because it sees exactly what the compiler sees.
Two alternatives were ruled out: a tracer set through `:test_elixirc_options`
only fires when `mix test` itself requires the files (so it costs a full
test run), and `mix test --stale` is timestamp-based, which says nothing in a
cold CI checkout.

Fallbacks, per test file, recorded as the entry's `mode`:

* `:tracer`: required fine (the normal case)
* `:ast`: requiring failed even when retried on its own; module references
  come from `Code.string_to_quoted/1` with the file's `alias` forms resolved.
  That misses what macros (`use MyApp.DataCase`) inject, so the test runs
  whenever anything is affected; the references are kept only to load the
  test files it needs.
* `:always`: the file does not even parse (then its `reads` is `["**"]`),
  or one of its `affected_by` globs is malformed, not in normal form or
  names a directory (see
  **Configuration**); it runs whenever anything is affected.

Test files that exist but are not in the map (a map prebuilt before they
were added), and entries whose recorded hashes no longer match, are selected
whenever anything is affected too, and selecting one is a full run (see
**Map freshness**).

A failing `test_helper.exs` or `app.start` is reported on stderr and does not
stop the map: tracing only needs the test modules to compile.


On a 12-file fixture project `mix affected.map` takes about 0.5s wall
time, of which the tracer pass is under 0.1s. It compiles the project and
requires every test file, so on a large project expect roughly the time
`mix test` spends loading test files. If that is too slow for every CI run,
build the map once on the main branch, cache it, and pass it in with
`--map` (see **Map freshness**).

## Escape hatches

* Run plain `mix test`: nothing here is in its path.
* Add a path to `extra_global_invalidation` to force a full run whenever it
  changes.
* Use `mappings` or `@moduletag affected_by:` for dependencies the compiler
  cannot see.
* Pass a prebuilt or freshly built map with `--map`; delete
  `_build/test/mix_affected/test_map.etf` to rebuild locally.


## Limitations

* **Dynamic dispatch** (`apply/3`, `Module.concat/1`, module names from
  config, behaviours resolved at runtime) is invisible to xref and to the
  tracer: declare it with `@moduletag affected_by:` or `mappings`. The one
  exception is a Mox mock (`Mox.defmock(MyApp.MockClient, for: MyApp.Client)`
  in `test_helper.exs`): a test naming the mock references the behaviours it
  is for.
* **Protocols** dispatch at runtime, so no xref edge reaches an impl. The
  map records each project impl (`defimpl`, `@derive`) with the file of the
  type it is for, and selection treats that file as depending on the impl:
  changing `defimpl Enumerable, for: MyApp.Bag` affects `bag.ex` and
  everything that depends on it. An affected impl for a type outside the
  project (`Integer`, `Any`, a dependency's struct) is a full run
  (`unmapped_file:<impl>`), as is a changed file defining an impl the map
  has not recorded (added after a prebuilt map). Callers that only reach an
  impl through the protocol module, never naming the type, are covered only
  through the type's dependents; an impl retargeted to another `for:` after
  a prebuilt map was built is attached to its old type.
* **Runtime configuration** (`Application.get_env/2`) is not tracked; that is
  why `config/**` is a global invalidation.
* **External resources** (`.heex`, `.po`, `@external_resource` files, priv
  data) are not graph nodes, so changing one is a full run
  (`unmapped_file:`). `mappings` and `affected_by` do not narrow this: they
  match affected files, and an unmapped file ends selection first.
* **Umbrella projects** are not supported yet: at an umbrella root the answer
  is always a full run (`test_map_unavailable:umbrella_not_supported`), and
  apps sharing a relative path make the graph refuse (`ambiguous_paths`).
* **Map freshness (maps built at another commit).** A map is reused as long
  as it exists in the current format (an older format is rebuilt). Each
  entry records content hashes of its test file and of every file it
  references; when any of those changed since the map was built (a local map
  older than your edits, a `--map` prebuilt on another commit), its
  references may be out of date: the test may now need a helper-defining
  test file the entry does not list, and a selection without it would fail
  where the full suite passes. Such an entry (or a test file the map does
  not know) is selected whenever anything is affected, and selecting it is a
  full run with exit status 2 (`test_map_unavailable:stale_entry:<test
  file>`). A map built in the run (the default when none exists) is never
  stale; a map prebuilt on another commit is a full run for any change to a
  file a test references or to a test file, so delete a local map after
  editing tests. What this does not catch: a macro whose *helper* (called at
  expansion time, not referenced by the test) changed between the map's
  commit and the base so that it now injects different references; delete
  the map or build it at the base.
* Non-test `.exs` files under `test/` (support scripts required by the
  helper) are not graph nodes: changing one is a full run.
* With `--base` in a project that is a subdirectory of the repository,
  paths are re-rooted to the project, and a changed file outside the project
  forces a full run (`unmapped_file:<absolute path>`): a sibling directory in
  a monorepo always does, whether the change there is committed, uncommitted
  or a new untracked file.


## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version:

    mix format --check-formatted && mix credo --strict && mix dialyzer && mix test

## License

MIT. See [LICENSE](LICENSE).
