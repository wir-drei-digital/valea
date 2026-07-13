defmodule Valea.Acp.ConnectionTest do
  use ExUnit.Case, async: true

  alias Valea.Acp.Connection

  # --- helpers ---

  defp frame(map), do: Jason.encode!(map) <> "\n"

  defp decode_lines(frames), do: Enum.map(frames, &Jason.decode!/1)

  defp boot(mode, known \\ MapSet.new()) do
    {state, [init_frame]} =
      Connection.new(%{
        cwd: "/ws",
        mode: mode,
        conversation_id: if(mode == :new, do: nil, else: "conv-1"),
        known_message_ids: known,
        client_version: "0.3.0"
      })

    init = Jason.decode!(init_frame)
    assert init["method"] == "initialize"
    assert init["params"]["clientInfo"]["name"] == "valea"
    {state, init["id"]}
  end

  defp init_response(id, caps \\ %{}) do
    frame(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => Map.merge(%{"protocolVersion" => 1}, caps)
    })
  end

  # Drive boot -> initialize response -> session/new response so the connection
  # is ready to reduce session/update notifications. Returns state with the
  # agent session id "sess-xyz".
  defp connected_state do
    {state, init_id} = boot(:new)
    {state, _, _, _} = Connection.handle_bytes(state, init_response(init_id))

    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        frame(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "sess-xyz"}})
      )

    state
  end

  # Drive boot(:load) through initialize + session/load so the connection is
  # ready to reduce replayed history. `known` seeds launch.known_message_ids.
  defp loaded_state(known) do
    {state, init_id} = boot(:load, known)

    {state, _, _, _} =
      Connection.handle_bytes(
        state,
        init_response(init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      )

    {state, _, _, _} =
      Connection.handle_bytes(state, frame(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}))

    state
  end

  defp update(kind, fields) do
    frame(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s", "update" => Map.put(fields, "sessionUpdate", kind)}
    })
  end

  # === 1. Fresh handshake ===

  test "fresh handshake: init -> response -> session/new with mcpServers [] + cwd; then session ready" do
    {state, init_id} = boot(:new)

    {state, _items, replies, effects} = Connection.handle_bytes(state, init_response(init_id))

    assert [%{"method" => "session/new", "params" => params}] = decode_lines(replies)
    assert params["cwd"] == "/ws"
    assert params["mcpServers"] == []
    assert effects == []

    {_state, _items, _replies, effects} =
      Connection.handle_bytes(
        state,
        frame(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "sess-abc"}})
      )

    assert {:session_ready} in effects
    assert {:conversation_id, "sess-abc"} in effects
  end

  # === 2. Version mismatch ===

  test "version mismatch yields {:handshake_failed, _} and no session frame" do
    {state, init_id} = boot(:new)

    {_state, items, replies, effects} =
      Connection.handle_bytes(state, init_response(init_id, %{"protocolVersion" => 2}))

    assert items == []
    assert replies == []
    assert Enum.any?(effects, &match?({:handshake_failed, _}, &1))
  end

  # === 3. Resume preference ===

  test "resume preference: resume cap -> session/resume; load cap -> session/load; neither -> session/new" do
    # sessionCapabilities.resume true -> session/resume
    {state, init_id} = boot(:resume)

    {_s, _i, replies, _e} =
      Connection.handle_bytes(
        state,
        init_response(init_id, %{"sessionCapabilities" => %{"resume" => true}})
      )

    assert [%{"method" => "session/resume", "params" => p}] = decode_lines(replies)
    assert p["sessionId"] == "conv-1"
    assert p["mcpServers"] == []

    # only loadSession true -> session/load
    {state, init_id} = boot(:resume)

    {_s, _i, replies, _e} =
      Connection.handle_bytes(
        state,
        init_response(init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      )

    assert [%{"method" => "session/load", "params" => %{"sessionId" => "conv-1"}}] =
             decode_lines(replies)

    # neither -> session/new
    {state, init_id} = boot(:resume)
    {_s, _i, replies, _e} = Connection.handle_bytes(state, init_response(init_id))
    assert [%{"method" => "session/new"}] = decode_lines(replies)
  end

  # === 4. Load replay dedup ===

  test "load replay dedup: known messageId collapses to zero items; a fresh one produces one" do
    state = loaded_state(MapSet.new(["m1"]))

    dup =
      update("user_message_chunk", %{
        "messageId" => "m1",
        "content" => %{"type" => "text", "text" => "a"}
      })

    {state, items1, _, _} = Connection.handle_bytes(state, dup)
    {state, items2, _, _} = Connection.handle_bytes(state, dup)
    assert items1 == []
    assert items2 == []

    fresh =
      update("user_message_chunk", %{
        "messageId" => "m2",
        "content" => %{"type" => "text", "text" => "b"}
      })

    {_state, items3, _, _} = Connection.handle_bytes(state, fresh)
    assert [%{"type" => "message", "text" => "b"}] = items3
  end

  # === 5. Prompt turn ===

  test "prompt emits session/prompt; turn_in_flight? true; end_turn + error responses complete the turn" do
    state = connected_state()

    {state, items, frames} = Connection.prompt(state, "hi")
    assert items == []
    assert [%{"method" => "session/prompt", "params" => params}] = decode_lines(frames)
    assert params["sessionId"] == "sess-xyz"
    assert [%{"type" => "text", "text" => "hi"}] = params["prompt"]
    assert Connection.turn_in_flight?(state)

    prompt_id = Jason.decode!(hd(frames))["id"]

    {state, turn_items, _replies, effects} =
      Connection.handle_bytes(
        state,
        frame(%{"jsonrpc" => "2.0", "id" => prompt_id, "result" => %{"stopReason" => "end_turn"}})
      )

    assert {:turn, "end_turn"} in effects
    assert Enum.any?(turn_items, &(&1["type"] == "turn" and &1["stop_reason"] == "end_turn"))
    refute Connection.turn_in_flight?(state)

    # An error response to a prompt also completes the turn.
    {state, _items, [frame2]} = Connection.prompt(state, "again")
    err_id = Jason.decode!(frame2)["id"]

    {state, _items, _replies, effects} =
      Connection.handle_bytes(
        state,
        frame(%{
          "jsonrpc" => "2.0",
          "id" => err_id,
          "error" => %{"code" => -32_000, "message" => "boom"}
        })
      )

    assert {:turn, "error"} in effects
    refute Connection.turn_in_flight?(state)
  end

  # === 6. Message accumulation ===

  test "two agent_message_chunk updates concatenate into one message item id msg-<turn>" do
    state = connected_state()

    {state, [i1], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "Hel"}})
      )

    {_state, [i2], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "lo"}})
      )

    assert i1["type"] == "message" and i1["text"] == "Hel"
    assert i1["id"] == "msg-0"
    assert i2["id"] == i1["id"] and i2["text"] == "Hello"
  end

  # === 7. Tool merge + output cap ===

  test "tool_call then tool_call_update merge by id; output capped tail-kept" do
    state = connected_state()

    {state, [t1], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{
          "toolCallId" => "tc1",
          "title" => "Edit",
          "kind" => "edit",
          "status" => "in_progress"
        })
      )

    {state, [t2], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc1",
          "status" => "completed",
          "content" => [%{"type" => "text", "text" => "done"}]
        })
      )

    assert t1["id"] == "tc1" and t1["status"] == "in_progress"
    assert t2["id"] == "tc1" and t2["status"] == "completed" and t2["title"] == "Edit"
    assert t2["output"] == "done"

    # Output cap: feed > 64 KiB across in_progress chunks (id survives), assert
    # the tail is kept and total stays under the cap.
    cap = Connection.max_tool_output()
    big = String.duplicate("x", div(cap, 2) + 1000)

    state =
      Enum.reduce(1..3, state, fn _i, st ->
        {st, [_i], _, _} =
          Connection.handle_bytes(
            st,
            update("tool_call_update", %{
              "toolCallId" => "tc2",
              "status" => "in_progress",
              "content" => [%{"type" => "text", "text" => big}]
            })
          )

        st
      end)

    {_state, [item], _, _} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{
          "toolCallId" => "tc2",
          "status" => "in_progress",
          "content" => [%{"type" => "text", "text" => "tail-marker"}]
        })
      )

    assert byte_size(item["output"]) <= cap
    assert String.ends_with?(item["output"], "tail-marker")
  end

  # === 8. Permission round-trip ===

  test "permission request -> item + effect; answer by kind -> matching optionId; re-answer is a no-op" do
    state = connected_state()

    req =
      frame(%{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "session/request_permission",
        "params" => %{
          "sessionId" => "sess-xyz",
          "toolCall" => %{
            "title" => "rm -rf",
            "kind" => "execute",
            "rawInput" => %{"command" => "rm -rf", "path" => "/tmp/foo"}
          },
          "options" => [
            %{"optionId" => "opt-allow", "name" => "Allow", "kind" => "allow_once"},
            %{"optionId" => "opt-reject", "name" => "Reject", "kind" => "reject_once"}
          ]
        }
      })

    {state, [item], _replies, effects} = Connection.handle_bytes(state, req)
    assert item["type"] == "permission" and item["resolved"] == false
    assert item["options"] |> Enum.map(& &1["kind"]) == ["allow_once", "reject_once"]
    assert item["command"] == "rm -rf"
    assert item["kind"] == "execute"
    assert item["rawInput"] == %{"command" => "rm -rf", "path" => "/tmp/foo"}

    assert {:permission_requested, effect_item} =
             Enum.find(effects, &match?({:permission_requested, _}, &1))

    assert effect_item["kind"] == "execute"
    assert effect_item["rawInput"] == %{"command" => "rm -rf", "path" => "/tmp/foo"}

    {state, [resolved], [reply]} = Connection.answer_permission(state, item["id"], "allow_once")
    decoded = Jason.decode!(reply)
    assert decoded["id"] == 9
    assert decoded["result"]["outcome"]["outcome"] == "selected"
    assert decoded["result"]["outcome"]["optionId"] == "opt-allow"

    assert resolved == %{
             "id" => "perm-9",
             "type" => "permission",
             "resolved" => true,
             "outcome" => "allow_once"
           }

    # Answering again: the pending entry is gone -> no frames.
    assert {^state, [], []} = Connection.answer_permission(state, item["id"], "allow_once")
  end

  # === 9. Cancellation ===

  test "cancel emits the cancelled outcome FIRST, then session/cancel; perms cleared" do
    state = connected_state()

    req =
      frame(%{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "session/request_permission",
        "params" => %{
          "toolCall" => %{"title" => "Run"},
          "options" => [%{"optionId" => "a", "name" => "Allow", "kind" => "allow_once"}]
        }
      })

    {state, [_item], _, _} = Connection.handle_bytes(state, req)

    {state, frames} = Connection.cancel(state)
    [first, second] = decode_lines(frames)

    assert first["id"] == 9
    assert first["result"]["outcome"]["outcome"] == "cancelled"
    assert second["method"] == "session/cancel"

    # Perms cleared -> a later answer is a no-op.
    assert {^state, [], []} = Connection.answer_permission(state, "perm-9", "allow_once")
  end

  # === 10. Config ===

  test "config_option_update -> config item; set_config_option selects the right wire method" do
    state = connected_state()

    # Before any config option is seen, set_config_option falls back to set_mode.
    {_s, [mode_frame]} = Connection.set_config_option(state, "cfg-model", "opus")

    assert %{"method" => "session/set_mode", "params" => %{"modeId" => "opus"}} =
             Jason.decode!(mode_frame)

    {state, [item], _, _} =
      Connection.handle_bytes(
        state,
        update("config_option_update", %{
          "configId" => "model",
          "name" => "Model",
          "value" => "sonnet",
          "options" => [%{"id" => "sonnet"}, %{"id" => "opus"}]
        })
      )

    assert item == %{
             "id" => "config-model",
             "type" => "config",
             "name" => "Model",
             "category" => nil,
             "current" => "sonnet",
             "options" => [%{"id" => "sonnet"}, %{"id" => "opus"}]
           }

    # Now that options were seen, set_config_option uses the config wire method.
    {_s, [cfg_frame]} = Connection.set_config_option(state, "model", "opus")
    decoded = Jason.decode!(cfg_frame)
    assert decoded["method"] == "session/set_config_option"

    assert decoded["params"] == %{
             "sessionId" => "sess-xyz",
             "configId" => "model",
             "value" => "opus"
           }
  end

  # === 11. Garbage / buffer cap ===

  test "garbage line is dropped without items; a > 1 MiB line resets the buffer without crashing" do
    state = connected_state()

    {_state, items, replies, effects} = Connection.handle_bytes(state, "not json\n")
    assert items == []
    assert replies == []
    assert effects == []

    cap = Connection.max_line_bytes()
    flood = String.duplicate("x", cap + 1)
    {state, items, _, _} = Connection.handle_bytes(state, flood)
    assert Enum.any?(items, &(&1["id"] == "error-buf"))

    # Buffer reset -> a subsequent valid frame parses cleanly.
    {_state, [item], _, _} =
      Connection.handle_bytes(
        state,
        update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "ok"}})
      )

    assert item["type"] == "message" and item["text"] == "ok"
  end

  # === 12. Unknown agent->client request ===

  test "unknown agent request (fs/read_text_file, id 4) gets an immediate -32601 reply" do
    state = connected_state()

    req =
      frame(%{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "fs/read_text_file",
        "params" => %{"path" => "/etc/passwd"}
      })

    {_state, items, replies, _effects} = Connection.handle_bytes(state, req)
    assert items == []
    assert [%{"jsonrpc" => "2.0", "id" => 4, "error" => err}] = decode_lines(replies)
    assert err["code"] == -32_601
    assert err["message"] == "Method not found"
  end

  # === 13. usage_update + session_info_update singletons ===

  test "usage_update and session_info_update produce their singleton items" do
    state = connected_state()

    {state, [usage], _, _} =
      Connection.handle_bytes(
        state,
        update("usage_update", %{"inputTokens" => 100, "outputTokens" => 20})
      )

    assert usage["id"] == "usage"
    assert usage["type"] == "usage"
    assert usage["inputTokens"] == 100
    assert usage["outputTokens"] == 20
    refute Map.has_key?(usage, "sessionUpdate")

    {_state, [info], _, _} =
      Connection.handle_bytes(state, update("session_info_update", %{"title" => "My Session"}))

    assert info == %{"id" => "session_info", "type" => "session_info", "title" => "My Session"}
  end
end

# Task 1.3: the launch map's two optional Phase-5 fields —
# `additional_roots` (-> native `additionalDirectories`) and
# `managed_settings` (-> `_meta.claudeCode.options.managedSettings`, per
# docs/notes/acp-launch-contract.md). Contract-gated: absent today, so the
# baseline `session/new` frame stays unchanged (first test below).
defmodule Valea.Acp.ConnectionLaunchTest do
  use ExUnit.Case, async: true
  alias Valea.Acp.Connection

  defp session_new_frame(launch) do
    {state, [init_frame]} = Connection.new(launch)
    # advance the handshake to the point session/new is emitted, correlating
    # the response to whatever rpc id the initialize request actually used
    # (Connection.new/1 starts next_id at 1, not 0).
    init_id = Jason.decode!(init_frame)["id"]

    init_resp =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => init_id,
        "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}
      })

    {_state, _items, frames, _effects} = Connection.handle_bytes(state, init_resp <> "\n")
    frames |> Enum.map(&Jason.decode!/1) |> Enum.find(&(&1["method"] == "session/new"))
  end

  test "session/new carries cwd (baseline, unchanged)" do
    frame =
      session_new_frame(%{
        cwd: "/icms/coaching",
        mode: :new,
        conversation_id: nil,
        known_message_ids: MapSet.new(),
        client_version: "test"
      })

    assert frame["params"]["cwd"] == "/icms/coaching"
    assert frame["params"] == %{"cwd" => "/icms/coaching", "mcpServers" => []}
  end

  test "session/new carries additional read roots and the managed-settings posture when present" do
    frame =
      session_new_frame(%{
        cwd: "/icms/coaching",
        mode: :new,
        conversation_id: nil,
        known_message_ids: MapSet.new(),
        client_version: "test",
        additional_roots: ["/icms/legal"],
        managed_settings:
          ~s|{"permissions":{"deny":["Read(/ws/logs/**)"],"ask":["Write","Bash"]}}|
      })

    # exact field placement per docs/notes/acp-launch-contract.md — assert the values reach the frame
    assert frame["params"]["cwd"] == "/icms/coaching"
    assert "/icms/legal" in frame["params"]["additionalDirectories"]

    assert get_in(frame, ["params", "_meta", "claudeCode", "options", "managedSettings"]) =~
             "Write"
  end
end
