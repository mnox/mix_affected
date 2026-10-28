# Fixture projects are compiled in temp copies and depend on this repo by path.
System.put_env("MIX_AFFECTED_PATH", File.cwd!())

# The XrefJson adapter shells out to `mix xref graph --format json`, which
# only exists on Elixir >= 1.19. Run that suite under a 1.19+ toolchain.
exclude = if Version.match?(System.version(), ">= 1.19.0"), do: [], else: [:xref_json]

ExUnit.start(exclude: exclude)
