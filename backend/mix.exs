defmodule Valea.MixProject do
  use Mix.Project

  def project do
    [
      app: :valea,
      version: "0.2.0",
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
        include_executables_for: [:unix, :windows],
        steps: [:assemble, &Burrito.wrap/1],
        # One target per build host, selected via BURRITO_TARGET
        # (scripts/build-release.sh derives it from uname): the sidecar
        # embeds natively-compiled NIFs (exqlite's sqlite3, erlexec's port
        # program), so cross-wrapping a release assembled on a different
        # host would ship the wrong binaries. Never build these cross.
        #
        # windows_x64 is the Windows bring-up target (windows-support spec
        # A1/A2): the release is ASSEMBLED on a Windows host, where erlexec
        # is dropped (its C++ port program is Unix-only, spec A1) and the
        # exqlite/mdex NIFs compile native. Wrapped for that host only, like
        # the others. See
        # docs/superpowers/specs/2026-07-19-windows-support-design.md.
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64],
            linux_x64: [os: :linux, cpu: :x86_64],
            windows_x64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Valea.Application, []},
      # :inets — the OTP `:httpc` client `Valea.Calendar.Fetch` is built on;
      # listed here so releases carry it.
      extra_applications: [:logger, :runtime_tools, :inets] ++ platform_extra_applications()
    ]
  end

  defp platform_extra_applications do
    case :os.type() do
      {:win32, _} -> []
      _ -> [:erlexec]
    end
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
      {:yaml_elixir, "~> 2.11"},
      {:tzdata, "~> 1.1"},
      {:gen_smtp, "~> 1.2"},
      {:floki, "~> 0.36"},
      {:codepagex, "~> 0.1"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # >= 1.6: the 1.5.x line pins zig 0.15.2, whose build runner can't link
      # libSystem against the macOS 26 SDK (release CI + local packaging both
      # fail); 1.6.0 moves the pin to zig 0.16.0, which scripts/build-release.sh
      # fetches. Keep this constraint and that script's ZIG_VERSION in lockstep.
      {:burrito, "~> 1.6", runtime: false}
    ] ++ platform_deps()
  end

  # erlexec is Unix-only — its C++ port program does not COMPILE on Windows
  # (windows-support spec A1), so on a Windows build host the dependency
  # must not exist at all. Native-per-platform builds make this branch safe:
  # the host IS the target.
  defp platform_deps do
    case :os.type() do
      {:win32, _} -> []
      _ -> [{:erlexec, "~> 2.0"}]
    end
  end

  defp aliases do
    [
      setup: ["deps.get"],
      lint: ["compile", "credo"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
