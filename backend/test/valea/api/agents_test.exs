defmodule Valea.Api.AgentsTest do
  @moduledoc """
  Direct Ash-action coverage for the Task 6.2/6.3 additions to
  `Valea.Api.Agents` (`list_recent_sessions_by_icm`, `list_sessions_for`,
  `create_follow_up`) — same style as `Valea.Api.IcmsTest`: calls each
  generic action straight through `Ash.ActionInput.for_action/3` +
  `Ash.run_action/1`, bypassing the RPC/channel transport entirely (that
  layer is exercised by the codegen'd client + `bun run check`, not this
  suite). `Valea.AgentsTest` covers the underlying `Valea.Agents` functions'
  behavior in depth; this suite only confirms the Ash action wiring
  (argument plumbing, typed-field return shape, error mapping).
  """
  use ExUnit.Case, async: false

  import Valea.AgentCase,
    only: [start_session: 3, kill_session: 1, mount_test_icm!: 2, open_workspace!: 1]

  alias Valea.Api.Agents
  alias Valea.Mounts
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

  test "create_follow_up inherits the original session's ICM", %{
    ws: ws,
    generation: generation,
    icm: icm
  } do
    {:ok, %{id: original_id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    on_exit(fn -> kill_session(original_id) end)

    assert {:ok, %{id: follow_up_id}} =
             run(:create_follow_up, %{session_id: original_id, generation: generation})

    on_exit(fn -> kill_session(follow_up_id) end)
    assert follow_up_id != original_id
  end

  test "create_follow_up surfaces icm_unavailable once the ICM is unmounted", %{
    ws: ws,
    generation: generation,
    icm: icm
  } do
    {:ok, %{id: original_id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    kill_session(original_id)

    {:ok, _path} = Mounts.unmount(ws, icm.mount_key)

    assert {:error, error} =
             run(:create_follow_up, %{session_id: original_id, generation: generation})

    assert %Valea.Api.Error{code: "icm_unavailable"} = error.errors |> hd()
  end

  test "create_follow_up surfaces original_not_found for an unknown session id", %{
    generation: generation
  } do
    assert {:error, error} = run(:create_follow_up, %{session_id: "nope", generation: generation})
    assert %Valea.Api.Error{code: "original_not_found"} = error.errors |> hd()
  end

  test "create_follow_up rejects a stale generation with workspace_changed", %{
    ws: ws,
    generation: generation,
    icm: icm
  } do
    {:ok, %{id: original_id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    on_exit(fn -> kill_session(original_id) end)

    stale = generation - 1

    assert {:error, error} =
             run(:create_follow_up, %{session_id: original_id, generation: stale})

    assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()
  end
end
