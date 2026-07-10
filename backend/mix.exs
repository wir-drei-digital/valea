defmodule Valea.MixProject do
  use Mix.Project

  def project do
    [
      app: :valea,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  defp releases do
    [
      valea: [include_executables_for: [:unix]],
      valea_desktop: [
        include_executables_for: [:unix],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [targets: [macos_arm: [os: :darwin, cpu: :aarch64]]]
      ]
    ]
  end

  def application do
    [
      mod: {Valea.Application, []},
      extra_applications: [:logger, :runtime_tools, :erlexec]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_sqlite, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_typescript, "~> 0.17"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:mdex, "~> 0.7"},
      {:bandit, "~> 1.5"},
      {:dotenvy, "~> 1.0"},
      {:corsica, "~> 2.1"},
      {:file_system, "~> 1.0"},
      {:erlexec, "~> 2.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      lint: ["compile", "credo"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
