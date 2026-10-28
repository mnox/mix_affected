defmodule Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      deps: [
        {:mix_affected,
         path: System.get_env("MIX_AFFECTED_PATH", Path.expand("../..", __DIR__)),
         only: [:dev, :test],
         runtime: false}
      ]
    ]
  end
end
