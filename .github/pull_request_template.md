## What and why

## Checklist

- [ ] A test that fails without this change
- [ ] `mix format --check-formatted && mix credo --strict && mix dialyzer && mix test` passes
- [ ] An entry under `## [Unreleased]` in `CHANGELOG.md`
- [ ] README updated if this changes the JSON output, exit codes or the `affected:` config
- [ ] If this narrows a selection, a test shows why the dropped tests cannot be affected
