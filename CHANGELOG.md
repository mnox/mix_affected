# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Issue and pull request templates, and docs and package builds in CI.
- README states that Windows is not supported yet.

## [0.1.0] - 2026-10-28

### Added

- `mix affected.files`: prints the test files a change set may affect, from
  `--base <git-ref>` or `--files <path|->`, as text or JSON (`schema_version`
  1), with `--explain` dependency chains.
- `mix affected.test`: runs `mix test` on that selection, or the whole suite
  on a full run.
- `mix affected.map`: builds the test map (test file to referenced source
  files) with a compiler tracer, falling back to AST analysis per file.
- `mix affected.report`: after a full `mix test`, lists failed test files a
  saved selection missed.
- Dependency graph adapters over `mix xref graph`: JSON on Elixir 1.19+, DOT
  before.
- Detection of tests that read repository files (`File.read!`,
  `Path.wildcard`, `@external_resource`, ...).
- Protocol implementations and Mox mocks resolved to the files they stand for.
- `affected:` project config: `global_invalidation`,
  `extra_global_invalidation`, `ignore` and `mappings`; per-test
  `@moduletag affected_by:`.
- Fail-open selection: anything the library cannot vouch for is a full run.
- `--base` is checked before any diff: an empty or blank ref, a ref starting
  with `-` (which git would read as an option) or one that does not resolve
  to a commit is a usage error (exit 1), never an empty change set. A ref
  with no merge base with `HEAD` is also exit 1. Diffs pass `--` after the
  revisions, so a ref never collides with a path.
- `--base` in a project that is a subdirectory of the repository re-roots
  changed paths to the project; a change outside it (committed, uncommitted
  or untracked, whatever the `diff.relative` config) forces a full run.
- Globs are checked up front, so a pattern that could never match is an
  error instead of a silent miss:
  - In `affected:` config, a malformed glob (an unclosed `{` or a stray `}`),
    a pattern naming a directory (`"lib/app/workers"`, or any glob ending in
    `/`), or a glob not in normal form (`"lib/./app/**"`, `"lib//app/**"`)
    is a usage error (exit 1) that names the fix, such as
    `"lib/app/workers/**"`. So is a `:test_paths`/`:test_pattern` that does
    not compile.
  - In a test's `affected_by`, the same globs are dropped and that test file
    always runs, with a warning on stderr. Selection never crashes on a glob.
  - A test's `reads` with a malformed literal glob, or a `[...]` character
    class, reads everything.

[Unreleased]: https://github.com/mnox/mix_affected/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mnox/mix_affected/releases/tag/v0.1.0
