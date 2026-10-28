# Contributing

Thanks for your interest in `mix_affected`. Bug reports, missed-test reports
and pull requests are welcome.

## The rule that matters

**When in doubt, run everything.** A selection that skips a test which would
have failed is the worst outcome this library can produce. A change that
narrows a selection must show, with a test, why the tests it drops cannot be
affected. A change that falls back to a full run in a new case needs no such
proof.

## Reporting a missed test

If `mix affected.report` (or a red main branch) shows a test the selection
missed, please open an issue with:

1. the changed files (`git diff --name-only --no-renames <base>...HEAD`)
2. the missed test file, and how it depends on the changed file (a macro,
   `apply/3`, a file it reads, config, ...)
3. `mix affected.files --files changed.txt --explain --format json` output
4. your Elixir and OTP versions

A minimal project that reproduces it is the fastest route to a fix.

## Development

You need Elixir 1.18 or later. To run the `:xref_json` suite you need
Elixir 1.19 or later.

```sh
mix deps.get
mix format --check-formatted && mix credo --strict && mix dialyzer && mix test
```

Fixture projects live in `fixtures/`, not `test/`, so their `*_test.exs`
files never load in this suite. The integration tests copy a fixture to a
temp dir, compile it and run the real tasks there.

## Pull requests

1. Add a test that fails without your change.
2. Keep the gates above green.
3. Add an entry under `## [Unreleased]` in `CHANGELOG.md`.
4. If you change the JSON output, the exit codes or the `affected:` config,
   update the README too. These are the public contract.
