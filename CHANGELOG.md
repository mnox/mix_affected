# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mnox/mix_affected/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mnox/mix_affected/releases/tag/v0.1.0
