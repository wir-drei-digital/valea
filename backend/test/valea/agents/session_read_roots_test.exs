# Session-start integration coverage for A-T10: read_roots is computed ONCE,
# centrally, in `SessionServer.init/1` — both construction sites
# (`Valea.Api.Agents.create_session` for chat, `Valea.Workflows.Runner.run`
# for workflows) route through `Valea.Agents.start_session/1` and land here,
# so this suite exercises the single real call path rather than re-deriving
# the expected roots by hand at each site.
defmodule Valea.Agents.SessionReadRootsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase

  # A fresh scaffold (T8) mints its own real, ENABLED mount at
  # `mounts/<slug-of-name>` from the template — naming the workspace
  # "Primary" lands it at exactly `mounts/primary`.
  setup do
    ws = AgentCase.open_workspace!("Primary")
    %{workspace: ws.path}
  end

  defp policy_ctx_for(id) do
    pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}})
    :sys.get_state(pid).policy_ctx
  end

  test "a started chat session's read_roots is [\"sources\", \"mounts/primary\"] — computed from Mounts.enabled",
       %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert Enum.sort(read_roots) == Enum.sort(["sources", "mounts/primary"])
  end

  test "disabling the mount BEFORE a session starts excludes it from that session's read_roots — its reads then ask-gate, not deny",
       %{workspace: workspace} do
    :ok = Valea.Mounts.set_enabled("primary", false)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: ["sources"]} = policy_ctx_for(id)
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

  test "a workflow session (via Valea.Workflows.Runner) also gets read_roots from Mounts.enabled",
       %{workspace: _workspace} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:ok, %{session_id: id}} =
             Valea.Workflows.Runner.run(
               "mounts/primary/Workflows/New Inquiry Triage.md",
               "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"
             )

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert Enum.sort(read_roots) == Enum.sort(["sources", "mounts/primary"])
  end
end
