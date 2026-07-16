# Session-start integration coverage for the split PermissionPolicy contract
# (Task 5.3/5.4): `policy_ctx.read_roots` is now a SINGLE absolute list —
# the primary ICM's own root, every direct related ICM's root, and any
# caller-supplied `read_paths` grant (`SessionScope.resolve/1`'s
# `additional_roots`, folded onto the scope by the harness `launch/2`
# directives — see that module's moduledoc). The OLD workspace-relative
# `read_roots` / absolute `extra_roots` split this file used to exercise,
# and the embedded-vs-external mount distinction it existed for, are
# retired: every mount is external and now contributes to the SAME list the
# same way. `Valea.Agents.SessionServer.default_read_roots/1` /
# `default_extra_roots/1` (what this file used to call out by name) are
# GONE — `SessionScope` is the one place read/write-root assembly lives.
#
# `Valea.Api.Agents.create_session` routes through
# `Valea.Agents.start_session/1` — this suite exercises
# `SessionServer.init/1`'s read/write-root wiring directly through
# `AgentCase.start_session/3`, including a granted session's read/write
# grants (`read_paths`/`write_paths`/`write_roots` — arbitrary per-session
# inputs, not tied to any particular session `kind`).
defmodule Valea.Agents.SessionReadRootsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase

  setup do
    ws = AgentCase.open_workspace!("Primary")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{workspace: ws.path, icm: icm}
  end

  defp policy_ctx_for(id) do
    pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}})
    :sys.get_state(pid).policy_ctx
  end

  test "a started chat session's read_roots is exactly the primary ICM's root when there is no related ICM and no extra grant",
       %{workspace: workspace, icm: icm} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots, cwd: cwd, workspace_root: workspace_root} =
             policy_ctx_for(id)

    assert cwd == icm.root
    assert workspace_root == workspace
    assert read_roots == [icm.root]
  end

  test "a direct related ICM's root joins read_roots on top of the primary's",
       %{workspace: workspace, icm: icm} do
    related_id = Ecto.UUID.generate()
    related = AgentCase.mount_test_icm!(workspace, name: "Related", id: related_id)

    File.write!(Path.join(icm.root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - id: #{related_id}
        name: "Related"
    ---
    """)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy", %{mount_key: icm.mount_key})
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert Enum.sort(read_roots) == Enum.sort([icm.root, related.root])
  end

  test "an unmounted-but-declared related ICM does not appear in read_roots (it surfaces as a context issue, not a grant)",
       %{workspace: workspace, icm: icm} do
    File.write!(Path.join(icm.root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - id: 00000000-0000-0000-0000-000000000000
        name: "Nope"
    ---
    """)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy", %{mount_key: icm.mount_key})
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert read_roots == [icm.root]
  end

  test "starting a session against a disabled primary mount fails with icm_unavailable — no session, no read_roots to leak",
       %{workspace: workspace, icm: icm} do
    :ok = Valea.Mounts.set_enabled(workspace, icm.mount_key, false)

    assert {:error, :icm_unavailable} =
             AgentCase.start_session(workspace, "happy", %{mount_key: icm.mount_key})
  end

  test "a granted session's read_paths join read_roots on top of the primary's",
       %{workspace: workspace, icm: icm} do
    extra_read = Path.join([workspace, "queue", "staging", "r1"])
    File.mkdir_p!(extra_read)

    {:ok, %{id: id}} =
      AgentCase.start_session(workspace, "happy", %{kind: "workflow", read_paths: [extra_read]})

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots, session_kind: "workflow"} = policy_ctx_for(id)
    assert Enum.sort(read_roots) == Enum.sort([icm.root, extra_read])
  end

  test "a granted session's write_paths/write_roots land verbatim in policy_ctx; a chat scope's are empty",
       %{workspace: workspace} do
    write_path = Path.join([workspace, "queue", "staging", "r1", "proposal.json"])
    write_root = Path.join([workspace, "queue", "staging", "r1", "proposals"])

    {:ok, %{id: chat_id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(chat_id) end)
    assert %{write_paths: [], write_roots: []} = policy_ctx_for(chat_id)

    {:ok, %{id: id}} =
      AgentCase.start_session(workspace, "happy", %{
        kind: "workflow",
        write_paths: [write_path],
        write_roots: [write_root]
      })

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{write_paths: [^write_path], write_roots: [^write_root]} = policy_ctx_for(id)
  end
end
