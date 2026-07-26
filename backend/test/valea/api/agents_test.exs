defmodule Valea.Api.AgentsTest do
  @moduledoc """
  Direct Ash-action coverage for the Task 6.2/6.3 additions to
  `Valea.Api.Agents` (`list_recent_sessions_by_icm`, `list_sessions_for`,
  `resume_agent_session`) — same style as `Valea.Api.IcmsTest`: calls each
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

  test "resume_agent_session revives an ended session IN PLACE — same id, same transcript, line 1 untouched",
       %{
         ws: ws,
         generation: generation,
         icm: icm
       } do
    {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    kill_session(id)
    wait_until(fn -> Registry.lookup(Valea.Agents.SessionRegistry, id) == [] end)

    transcript_path = Path.join(ws, "logs/sessions/#{id}.jsonl")
    [meta_before | _] = ws |> transcript_lines(id)

    assert {:ok, %{id: ^id}} =
             run(:resume_agent_session, %{session_id: id, generation: generation})

    on_exit(fn -> kill_session(id) end)

    # Live again under the SAME id (idempotent while live), and the
    # transcript's identity line is byte-identical.
    assert [_ | _] = Registry.lookup(Valea.Agents.SessionRegistry, id)

    assert {:ok, %{id: ^id}} =
             run(:resume_agent_session, %{session_id: id, generation: generation})

    assert [^meta_before | _] = transcript_lines(ws, id)
    assert File.regular?(transcript_path)

    # The revived server's attach snapshot carries the seeded history.
    assert {:ok, %{items: items, status: status}} = Valea.Agents.attach_or_replay(id)
    assert is_list(items)
    assert status in ["starting", "running"]
  end

  test "resume_agent_session surfaces icm_unavailable once the ICM is unmounted", %{
    ws: ws,
    generation: generation,
    icm: icm
  } do
    {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    kill_session(id)
    wait_until(fn -> Registry.lookup(Valea.Agents.SessionRegistry, id) == [] end)

    {:ok, _path} = Mounts.unmount(ws, icm.mount_key)

    assert {:error, error} =
             run(:resume_agent_session, %{session_id: id, generation: generation})

    assert %Valea.Api.Error{code: "icm_unavailable"} = error.errors |> hd()
  end

  test "resume_agent_session surfaces not_found for an unknown or traversal-shaped session id", %{
    generation: generation
  } do
    assert {:error, error} =
             run(:resume_agent_session, %{session_id: "nope", generation: generation})

    assert %Valea.Api.Error{code: "not_found"} = error.errors |> hd()

    assert {:error, error} =
             run(:resume_agent_session, %{session_id: "../secrets", generation: generation})

    assert %Valea.Api.Error{code: "not_found"} = error.errors |> hd()
  end

  defp transcript_lines(ws, id) do
    Path.join(ws, "logs/sessions/#{id}.jsonl") |> File.read!() |> String.split("\n", trim: true)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  test "resume_agent_session rejects a stale generation with workspace_changed", %{
    ws: ws,
    generation: generation,
    icm: icm
  } do
    {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: icm.mount_key})
    on_exit(fn -> kill_session(id) end)

    stale = generation - 1

    assert {:error, error} =
             run(:resume_agent_session, %{session_id: id, generation: stale})

    assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()
  end
end
