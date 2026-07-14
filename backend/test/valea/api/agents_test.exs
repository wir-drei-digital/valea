defmodule Valea.Api.AgentsTest do
  @moduledoc """
  Direct Ash-action coverage for the Task 6.2 additions to
  `Valea.Api.Agents` (`list_recent_sessions_by_icm`, `list_sessions_for`) —
  same style as `Valea.Api.IcmsTest`: calls each generic action straight
  through `Ash.ActionInput.for_action/3` + `Ash.run_action/1`, bypassing the
  RPC/channel transport entirely (that layer is exercised by the codegen'd
  client + `bun run check`, not this suite). `Valea.AgentsTest` covers the
  underlying `Valea.Agents` functions' behavior in depth; this suite only
  confirms the Ash action wiring (argument plumbing, typed-field return
  shape, error mapping).
  """
  use ExUnit.Case, async: false

  import Valea.AgentCase,
    only: [start_session: 3, kill_session: 1, mount_test_icm!: 2, open_workspace!: 1]

  alias Valea.Api.Agents
  alias Valea.Workspace.Manager

  setup do
    ws = open_workspace!("W")
    icm = mount_test_icm!(ws.path, name: "Primary")
    %{ws: ws.path, generation: Manager.generation(), icm: icm}
  end

  defp run(action, input) do
    Agents
    |> Ash.ActionInput.for_action(action, input)
    |> Ash.run_action()
  end

  test "list_recent_sessions_by_icm groups the open workspace's sessions", %{
    ws: ws,
    icm: icm
  } do
    {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    kill_session(id)

    assert {:ok, %{groups: [group]}} = run(:list_recent_sessions_by_icm, %{limit: 5})
    assert group.mount_key == icm.mount_key
    assert group.icm_name == "Primary"
    assert [%{id: ^id, live: false, status: "ended"}] = group.sessions
  end

  test "list_recent_sessions_by_icm is [] for a fresh workspace" do
    assert {:ok, %{groups: []}} = run(:list_recent_sessions_by_icm, %{limit: 5})
  end

  test "list_sessions_for pages a single ICM's history", %{ws: ws, icm: icm} do
    {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    kill_session(id)

    assert {:ok, %{sessions: [%{id: ^id}], next_cursor: nil}} =
             run(:list_sessions_for, %{mount_key: icm.mount_key, cursor: nil})
  end
end
