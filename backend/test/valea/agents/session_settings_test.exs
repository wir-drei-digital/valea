defmodule Valea.Agents.SessionSettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.SessionSettings

  defp scope(overrides) do
    Map.merge(
      %{
        workspace: %{id: "ws", root: "/ws", name: "W", generation: 1},
        primary_icm: %{mount_key: "coaching", id: "icm-1", root: "/icms/coaching", manifest: nil},
        related_icms: [
          %{
            mount_key: "legal",
            id: "icm-2",
            root: "/icms/legal",
            entrypoint: "CONTEXT.md",
            manifest: nil
          }
        ],
        cwd: "/icms/coaching",
        read_paths: [],
        write_paths: [],
        write_roots: [],
        managed_settings: nil,
        managed_context: nil,
        kind: "chat"
      },
      overrides
    )
  end

  test "allows reads in primary and related ICM roots as absolute globs" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    assert "Read(/icms/coaching/**)" in perms["allow"]
    assert "Read(/icms/legal/**)" in perms["allow"]
  end

  test "asks for edit/write/bash" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    assert "Write" in perms["ask"]
    assert "Edit" in perms["ask"]
    assert "Bash" in perms["ask"]
  end

  test "denies workspace operational state and web tools" do
    perms = SessionSettings.content(scope(%{}))["permissions"]

    for glob <- [
          "Read(/ws/logs/**)",
          "Read(/ws/config/**)",
          "Read(/ws/secrets/**)",
          "Read(/ws/runtime/**)",
          "Read(/ws/.git/**)",
          "Read(/ws/app.sqlite)"
        ] do
      assert glob in perms["deny"], "expected deny to include #{glob}"
    end

    assert "WebFetch" in perms["deny"]
    assert "WebSearch" in perms["deny"]
  end

  test "grants exact task input reads and exact workflow write paths/roots" do
    perms =
      SessionSettings.content(
        scope(%{
          read_paths: ["/ws/sources/mail/messages/42.md"],
          write_paths: ["/ws/queue/staging/r1/proposal.json"],
          write_roots: ["/ws/queue/staging/r1/proposals"]
        })
      )["permissions"]

    assert "Read(/ws/sources/mail/messages/42.md)" in perms["allow"]
    assert "Write(/ws/queue/staging/r1/proposal.json)" in perms["allow"]
    assert "Write(/ws/queue/staging/r1/proposals/**)" in perms["allow"]
  end

  test "context.md lists primary and related roots" do
    md = SessionSettings.context(scope(%{}))
    assert md =~ "/icms/coaching"
    assert md =~ "/icms/legal"
    assert md =~ "CONTEXT.md"
  end

  test "materialize! writes only context.md (posture is in-memory), never inside an ICM root" do
    tmp = Path.join(System.tmp_dir!(), "vss-#{System.unique_integer([:positive])}")
    icm = Path.join(tmp, "icm")
    File.mkdir_p!(icm)
    context = Path.join([tmp, "ws", "runtime", "sessions", "s1", "context.md"])

    :ok =
      SessionSettings.materialize!(
        scope(%{
          primary_icm: %{mount_key: "c", id: "i", root: icm, manifest: nil},
          cwd: icm,
          related_icms: [],
          managed_context: context
        })
      )

    assert File.exists?(context)
    refute File.exists?(Path.join([tmp, "ws", "runtime", "sessions", "s1", "settings.json"]))
    assert File.dir?(Path.join(icm, ".claude")) == false
    on_exit(fn -> File.rm_rf!(tmp) end)
  end
end
