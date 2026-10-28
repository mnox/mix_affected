defmodule Mocks.MixProject do
  use Mix.Project

  def project do
    [
      app: :mocks,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # The library under test; its own suite points MIX_AFFECTED_PATH at the repo
  # because fixtures are compiled in temp copies.
  defp deps do
    [
      {:mix_affected,
       path: System.get_env("MIX_AFFECTED_PATH", Path.expand("../..", __DIR__)),
       only: [:dev, :test],
       runtime: false},
      {:mox, "~> 1.2", only: :test}
    ]
  end
end
