# Security Policy

## Scope

`mix_affected` is a set of Mix tasks that run in your development and CI
environments. It reads your project's source files, runs `git` and
`mix xref`, compiles your project in the test env and, for `mix affected.test`,
runs `mix test`. It opens no network connections and handles no credentials.
Its realistic security surface is the paths and arguments it passes to `git`
and `mix`, and the files it reads and writes (`--files`, `--map`, `--output`,
`--selection`).

## Reporting a vulnerability

Please **do not** open a public issue for a security report.

Use GitHub's private vulnerability reporting instead:
**Security → Report a vulnerability** on this repository
(<https://github.com/mnox/mix_affected/security/advisories/new>).

You can expect an initial response within a few days. This is a personal,
best-effort project, so please be patient with any follow-up.

## Supported versions

Only the latest released version receives fixes.
