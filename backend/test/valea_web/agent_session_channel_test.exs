defmodule ValeaWeb.AgentSessionChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Valea.AgentCase

  @endpoint ValeaWeb.Endpoint

  setup do
    ws = AgentCase.open_workspace!()
    %{workspace: ws.path}
  end

  defp join(id) do
    socket(ValeaWeb.UserSocket, nil, %{})
    |> subscribe_and_join(ValeaWeb.AgentSessionChannel, "agent_session:" <> id)
  end

  test "join replay on a live session", %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")

    assert {:ok, reply, _socket} = join(id)
    # Usually "starting" (handshake still in flight when we join immediately
    # after start_session/3 returns), but not guaranteed under load.
    assert reply.status in ["starting", "running"]
    assert reply.busy == false
    assert reply.items == []
    assert reply.cursor == 0
  end

  test "join replay on an ended session comes from the transcript file", %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    :ok = Valea.Agents.SessionServer.stop(id)
    assert_receive {:session_exit, _code}, 10_000

    # `SessionServer.stop/1` only stops the adapter subprocess — the
    # (restart: :temporary) GenServer survives so the transcript stays
    # attachable. Kill the GenServer itself to force the file-replay path.
    :ok = AgentCase.kill_session(id)

    assert {:ok, reply, _socket} = join(id)
    assert reply.status == "ended"
    assert reply.busy == false
    assert Enum.any?(reply.items, &(&1["type"] == "message" and &1["role"] == "user"))
    assert Enum.any?(reply.items, &(&1["type"] == "message" and &1["role"] == "assistant"))
    assert reply.cursor > 0
  end

  test "seq gating: only seq > cursor is pushed, and the cursor advances", %{
    workspace: workspace
  } do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    assert {:ok, reply, socket} = join(id)
    assert reply.cursor == 0

    # Drive the gate directly (deterministic — no PubSub timing race): seq 0
    # is not > cursor 0, so it must be dropped; seq 1 is, so it must push and
    # the cursor must advance to 1.
    send(socket.channel_pid, {:session_event, 0, %{"id" => "x", "type" => "message"}})
    refute_push "event", %{seq: 0}

    send(socket.channel_pid, {:session_event, 1, %{"id" => "y", "type" => "message"}})
    assert_push "event", %{seq: 1, item: %{"id" => "y"}}

    # The cursor is now 1 — a re-delivery of the same seq is dropped too.
    send(socket.channel_pid, {:session_event, 1, %{"id" => "y", "type" => "message"}})
    refute_push "event", %{seq: 1}
  end

  test "prompt in, event out", %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    assert {:ok, _reply, socket} = join(id)

    push(socket, "prompt", %{"content" => "hello"})

    assert_push "event",
                %{item: %{"type" => "message", "role" => "user", "text" => "hello"}},
                10_000

    assert_push "event", %{item: %{"type" => "message", "role" => "assistant"}}, 10_000
    assert_push "event", %{item: %{"type" => "turn"}}, 10_000
  end

  test "permission answer path", %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "permission")
    assert {:ok, _reply, socket} = join(id)

    push(socket, "prompt", %{"content" => "write"})

    assert_push "event", %{item: %{"type" => "message", "role" => "user"}}, 10_000

    assert_push "event",
                %{item: %{"type" => "permission", "resolved" => false} = perm},
                10_000

    ref = push(socket, "permission", %{"item_id" => perm["id"], "kind" => "allow_once"})
    refute_reply ref, :error

    assert_push "event", %{item: %{"type" => "permission", "resolved" => true}}, 10_000
    assert_push "event", %{item: %{"type" => "turn"}}, 10_000
  end

  test "permission with an invalid kind replies error instead of crashing", %{
    workspace: workspace
  } do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    assert {:ok, _reply, socket} = join(id)

    ref = push(socket, "permission", %{"item_id" => "x", "kind" => "bogus"})
    assert_reply ref, :error, %{reason: "invalid_permission_kind"}
  end

  test "unknown session id is a join error", %{workspace: _workspace} do
    assert {:error, %{reason: "session_not_found"}} = join("no-such-session")
  end

  test "inbound events on an ended session reply session_not_found", %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
    :ok = Valea.Agents.SessionServer.stop(id)
    assert_receive {:session_exit, _code}, 10_000
    :ok = AgentCase.kill_session(id)

    assert {:ok, _reply, socket} = join(id)

    ref = push(socket, "prompt", %{"content" => "hi"})
    assert_reply ref, :error, %{reason: "session_not_found"}

    ref2 = push(socket, "stop", %{})
    assert_reply ref2, :error, %{reason: "session_not_found"}
  end

  test "catch-all handle_in does not crash on an unknown event", %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    assert {:ok, _reply, socket} = join(id)

    push(socket, "bogus_event", %{"whatever" => 1})
    # The channel process is still alive and answers normal events afterward.
    ref = push(socket, "cancel", %{})
    refute_reply ref, :error
  end

  describe "list_sessions/0" do
    test "orders newest-first and merges live flags", %{workspace: workspace} do
      {:ok, %{id: id1}} = AgentCase.start_session(workspace, "happy")
      Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id1)
      :ok = Valea.Agents.SessionServer.prompt(id1, "hi")
      assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
      :ok = Valea.Agents.SessionServer.stop(id1)
      assert_receive {:session_exit, _code}, 10_000
      :ok = AgentCase.kill_session(id1)

      # started_at carries microsecond precision — a short sleep is enough to
      # make sure id2's timestamp strictly sorts after id1's.
      Process.sleep(10)
      {:ok, %{id: id2}} = AgentCase.start_session(workspace, "happy")

      assert {:ok, sessions} = Valea.Agents.list_sessions()
      ids = Enum.map(sessions, & &1["id"])
      assert ids == [id2, id1]

      by_id = Map.new(sessions, &{&1["id"], &1})
      assert by_id[id1]["live"] == false
      assert by_id[id1]["status"] == "ended"
      assert by_id[id2]["live"] == true
      assert by_id[id2]["status"] in ["starting", "running"]
      assert by_id[id1]["kind"] == "chat"
      assert by_id[id1]["title"] == "Test"
    end

    test "no workspace open returns an empty list" do
      Valea.Workspace.Manager.close()
      assert {:ok, []} = Valea.Agents.list_sessions()
    end
  end
end
