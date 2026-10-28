defmodule MixAffected.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mnox/mix_affected"

  def project do
    [
      app: :mix_affected,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Runs only the tests a change can affect, using mix xref and a compiler-traced test map.",
      package: package(),
      name: "MixAffected",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      # Elixir >= 1.19 warns about non-test files under test/; test/support is
      # compiled support code, not misnamed tests. Fixture projects live in
      # fixtures/ so their *_test.exs files are never part of this suite.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :extra_return, :missing_return]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
