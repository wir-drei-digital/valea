# Session-start integration coverage for A-T10: read_roots is computed ONCE,
# centrally, in `SessionServer.init/1` — both construction sites
# (`Valea.Api.Agents.create_session` for chat, `Valea.Workflows.Runner.run`
# for workflows) route through `Valea.Agents.start_session/1` and land here,
# so this suite exercises the single real call path rather than re-deriving
# the expected roots by hand at each site.
defmodule Valea.Agents.SessionReadRootsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY
  # — a freshly scaffolded (v5) workspace carries no seeded mount, and
  # EVERY mount is now EXTERNAL (`rel_root: nil`). Per
  # `SessionServer.default_read_roots/1`'s own moduledoc comment, an
  # external mount's root NEVER joins `read_roots` (no workspace-relative
  # form) — it joins `extra_roots` instead (`default_extra_roots/1`). So
  # `read_roots` for a session is now just `["sources"]` plus any EXTRA
  # grant a caller adds (e.g. B3's per-run staging dir) — no mount ever
  # contributes to it any more; every mount's read grant flows through
  # `extra_roots`.
  setup do
    ws = AgentCase.open_workspace!("Primary")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{workspace: ws.path, icm: icm}
  end

  defp policy_ctx_for(id) do
    pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}})
    :sys.get_state(pid).policy_ctx
  end

  test "a started chat session's read_roots is just [\"sources\"] — no mount is embedded any more",
       %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert read_roots == ["sources"]
  end

  test "the enabled primary mount's root is in extra_roots", %{workspace: workspace, icm: icm} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{extra_roots: extra_roots} = policy_ctx_for(id)
    assert extra_roots == [icm.root]
  end

  test "disabling the mount BEFORE a session starts excludes its root from that session's extra_roots — its reads then ask-gate, not deny",
       %{workspace: workspace, icm: icm} do
    :ok = Valea.Mounts.set_enabled(workspace, icm.mount_key, false)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: ["sources"], extra_roots: []} = policy_ctx_for(id)
  end

  test "a second external mount stays OUT of read_roots but joins extra_roots (A2-T3) — the workspace-relative and absolute read surfaces are tracked separately",
       %{workspace: workspace, icm: icm} do
    ext = AgentCase.mount_test_icm!(workspace, name: "Ext")

    # Sanity: the external mount IS effective — it's excluded from
    # read_roots deliberately (rel_root: nil has no workspace-relative
    # form; PermissionPolicy would crash on it), not because it failed to
    # resolve. Its real root is what extra_roots carries instead.
    enabled = Valea.Mounts.enabled(workspace)
    assert "ext" in Enum.map(enabled, & &1.name)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots, extra_roots: extra_roots} = policy_ctx_for(id)
    refute nil in read_roots
    assert read_roots == ["sources"]
    assert Enum.sort(extra_roots) == Enum.sort([icm.root, ext.root])
  end

  test "disabling the second external mount BEFORE a session starts excludes only its root from extra_roots",
       %{workspace: workspace, icm: icm} do
    ext = AgentCase.mount_test_icm!(workspace, name: "Ext")
    :ok = Valea.Mounts.set_enabled(workspace, ext.mount_key, false)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{extra_roots: extra_roots} = policy_ctx_for(id)
    assert extra_roots == [icm.root]
  end

  test "an explicit policy_ctx extra_roots is NOT clobbered by the computed default",
       %{workspace: workspace} do
    {:ok, %{id: id}} =
      AgentCase.start_session(workspace, "happy", %{
        policy_ctx: %{
          workspace: workspace,
          session_kind: "chat",
          write_paths: [],
          extra_roots: ["/some/explicit/root"]
        }
      })

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{extra_roots: ["/some/explicit/root"]} = policy_ctx_for(id)
  end

  test "an explicit policy_ctx read_roots is NOT clobbered by the computed default",
       %{workspace: workspace} do
    {:ok, %{id: id}} =
      AgentCase.start_session(workspace, "happy", %{
        policy_ctx: %{
          workspace: workspace,
          session_kind: "chat",
          write_paths: [],
          read_roots: ["queue"]
        }
      })

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: ["queue"]} = policy_ctx_for(id)
  end

  test "a workflow session (via Valea.Workflows.Runner) also gets its own run staging dir in read_roots (B3), on top of the plain [\"sources\"] default",
       %{workspace: _workspace, icm: icm} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    File.mkdir_p!(Path.join(icm.root, "Workflows"))

    File.write!(
      Path.join(icm.root, "Workflows/New Inquiry Triage.md"),
      """
      ---
      enabled: true
      risk_level: medium
      approval:
        required: true
      ---
      # New Inquiry Triage

      ## Process

      1. Do the thing.
      """
    )

    assert {:ok, %{run_id: run_id, session_id: id}} =
             Valea.Workflows.Runner.run(
               Path.join(icm.root, "Workflows/New Inquiry Triage.md"),
               "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"
             )

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)

    assert Enum.sort(read_roots) == Enum.sort(["sources", "queue/staging/#{run_id}"])
  end
end
