defmodule SingleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :single_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      affected: [
        mappings: [{"lib/single_app/standalone.ex", ["test/single_app/mapped_*_test.exs"]}]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The library under test; its own suite points MIX_AFFECTED_PATH at the repo
  # because fixtures are compiled in temp copies.
  defp deps do
    [
      {:mix_affected,
       path: System.get_env("MIX_AFFECTED_PATH", Path.expand("../..", __DIR__)),
       only: [:dev, :test],
       runtime: false}
    ]
  end
end
