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
        burrito: [targets: desktop_sidecar_targets()]
      ]
    ]
  end

  # Burrito wraps every listed target, and a cross-OS wrap needs that target's
  # ERTS — so we build only the native target for the current build host. Each
  # platform packages its own sidecar (macOS → macos_arm, Linux → linux); the
  # Justfile picks the matching `burrito_out/valea_desktop_<target>` artifact.
  defp desktop_sidecar_targets do
    case :os.type() do
      {:unix, :darwin} -> [macos_arm: [os: :darwin, cpu: :aarch64]]
      {:unix, :linux} -> [linux: [os: :linux, cpu: :x86_64]]
      other -> raise "unsupported build host for the desktop sidecar: #{inspect(other)}"
    end
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
      {:yaml_elixir, "~> 2.11"},
      {:gen_smtp, "~> 1.2"},
      {:floki, "~> 0.36"},
      {:codepagex, "~> 0.1"},
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
