defmodule Valea.AgentsTest do
  @moduledoc """
  Direct coverage for `Valea.Agents`' Task 6.2 (grouped-by-ICM recent
  listing, per-ICM history paging) and Task 6.3 (`create_follow_up/2`)
  additions. Uses `Valea.AgentCase` throughout, same as
  `test/valea/agents/session_server_test.exs`.
  """
  use ExUnit.Case, async: false

  import Valea.AgentCase,
    only: [
      start_session: 3,
      kill_session: 1,
      mount_test_icm!: 2,
      open_workspace!: 1
    ]

  alias Valea.Agents
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    ws = open_workspace!("W")

    # Mounted in REVERSE alphabetical order so a passing "config order"
    # assertion can't be an accident of insertion order — `Mounts.list/1`
    # sorts by mount key, so "alpha" must come back before "zebra" below
    # regardless of which was mounted (or had sessions created) first.
    zebra = mount_test_icm!(ws.path, name: "Zebra")
    alpha = mount_test_icm!(ws.path, name: "Alpha")

    %{ws: ws.path, generation: Manager.generation(), zebra: zebra, alpha: alpha}
  end

  defp write_transcript!(workspace, id, mount_key, started_at) do
    dir = Path.join([workspace, "logs", "sessions"])
    File.mkdir_p!(dir)

    meta = %{
      "schema" => "session/v1",
      "id" => id,
      "acp_session_id" => nil,
      "workspace_id" => "ws-fixture",
      "workspace_name" => "W",
      "icm_mount" => mount_key,
      "icm_id" => "icm-fixture",
      "icm_name" => "Fixture",
      "icm_root" => "/tmp/fixture",
      "kind" => "chat",
      "workflow" => nil,
      "run_id" => nil,
      "title" => "Test",
      "harness" => "claude_code",
      "generation" => 1,
      "started_at" => started_at
    }

    File.write!(Path.join(dir, id <> ".jsonl"), Jason.encode!(meta) <> "\n")
  end

  defp iso(seconds_offset) do
    ~U[2026-01-01 00:00:00Z] |> DateTime.add(seconds_offset, :second) |> DateTime.to_iso8601()
  end

  # Writes a raw transcript line-1 metadata map as-is (unlike
  # `write_transcript!/4`, which always stamps `"schema" => "session/v1"`) —
  # lets a test build a transcript that does NOT carry the current schema,
  # to assert it's excluded.
  defp write_raw_transcript!(workspace, id, meta) do
    dir = Path.join([workspace, "logs", "sessions"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, id <> ".jsonl"), Jason.encode!(meta) <> "\n")
  end

  describe "list_sessions/0" do
    test "skips a transcript whose line 1 isn't schema session/v1 (spec: no reader for old transcripts)",
         %{ws: ws} do
      write_raw_transcript!(ws, "legacy-1", %{
        "id" => "legacy-1",
        "started_at" => iso(0),
        "title" => "Pre-redesign session"
      })

      write_transcript!(ws, "current-1", "some-mount", iso(1))

      assert {:ok, [%{"id" => "current-1"}]} = Agents.list_sessions()
    end
  end

  describe "list_recent_sessions_by_icm/1" do
    test "one group per ICM in config order, live before ended (newest first), capped at limit",
         %{ws: ws, zebra: zebra, alpha: alpha} do
      {:ok, %{id: z1}} = start_session(ws, "happy", %{mount_key: zebra.mount_key})
      Process.sleep(2)
      {:ok, %{id: z2}} = start_session(ws, "happy", %{mount_key: zebra.mount_key})
      Process.sleep(2)
      {:ok, %{id: z3}} = start_session(ws, "happy", %{mount_key: zebra.mount_key})
      Process.sleep(2)
      {:ok, %{id: z_live}} = start_session(ws, "happy", %{mount_key: zebra.mount_key})

      kill_session(z1)
      kill_session(z2)
      kill_session(z3)
      on_exit(fn -> kill_session(z_live) end)

      {:ok, %{id: a1}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      kill_session(a1)

      groups = Agents.list_recent_sessions_by_icm(3)

      assert Enum.map(groups, & &1.mount_key) == [alpha.mount_key, zebra.mount_key]

      [alpha_group, zebra_group] = groups
      assert alpha_group.icm_name == "Alpha"
      assert [%{id: ^a1, live: false, status: "ended"}] = alpha_group.sessions

      assert zebra_group.icm_name == "Zebra"
      assert length(zebra_group.sessions) == 3

      [s1, s2, s3] = zebra_group.sessions
      assert %{id: ^z_live, live: true} = s1
      assert %{id: ^z3, live: false} = s2
      assert %{id: ^z2, live: false} = s3
      refute Enum.any?(zebra_group.sessions, &(&1.id == z1))
    end

    test "only ICMs with at least one session are grouped", %{ws: ws, alpha: alpha} do
      {:ok, %{id: a1}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      kill_session(a1)

      assert [%{mount_key: mount_key}] = Agents.list_recent_sessions_by_icm(5)
      assert mount_key == alpha.mount_key
    end

    test "[] when no workspace is open" do
      Manager.close()
      assert Agents.list_recent_sessions_by_icm(5) == []
    end
  end

  describe "list_sessions_for/3" do
    test "filters to exactly one ICM's sessions", %{ws: ws, zebra: zebra, alpha: alpha} do
      {:ok, %{id: z1}} = start_session(ws, "happy", %{mount_key: zebra.mount_key})
      kill_session(z1)
      {:ok, %{id: a1}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      kill_session(a1)

      assert %{sessions: sessions, next_cursor: nil} =
               Agents.list_sessions_for(alpha.mount_key, nil)

      assert Enum.map(sessions, & &1.id) == [a1]
    end

    test "pages via a small page_size, newest first, no gaps or dupes across the full traversal",
         %{ws: ws, alpha: alpha} do
      ids =
        for i <- 1..25 do
          id = "hist-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          write_transcript!(ws, id, alpha.mount_key, iso(i))
          id
        end

      # Newest (largest i / latest started_at) first.
      expected = Enum.reverse(ids)

      {page1, cursor1} = fetch_page(alpha.mount_key, nil)
      assert length(page1) == 10
      assert cursor1 != nil

      {page2, cursor2} = fetch_page(alpha.mount_key, cursor1)
      assert length(page2) == 10
      assert cursor2 != nil

      {page3, cursor3} = fetch_page(alpha.mount_key, cursor2)
      assert length(page3) == 5
      assert cursor3 == nil

      assert page1 ++ page2 ++ page3 == expected
    end

    test "%{sessions: [], next_cursor: nil} when no workspace is open" do
      Manager.close()
      assert Agents.list_sessions_for("anything", nil) == %{sessions: [], next_cursor: nil}
    end

    defp fetch_page(mount_key, cursor) do
      %{sessions: sessions, next_cursor: next_cursor} =
        Agents.list_sessions_for(mount_key, cursor, 10)

      {Enum.map(sessions, & &1.id), next_cursor}
    end
  end

  describe "create_follow_up/2" do
    test "starts a new session with the SAME icm_mount as the original", %{
      ws: ws,
      generation: generation,
      alpha: alpha
    } do
      {:ok, %{id: original_id}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      on_exit(fn -> kill_session(original_id) end)

      assert {:ok, %{id: follow_up_id}} = Agents.create_follow_up(original_id, generation)
      on_exit(fn -> kill_session(follow_up_id) end)

      assert follow_up_id != original_id

      transcript = File.read!(Path.join(ws, "logs/sessions/#{follow_up_id}.jsonl"))
      [meta_line | _] = String.split(transcript, "\n", trim: true)
      meta = Jason.decode!(meta_line)

      assert meta["icm_mount"] == alpha.mount_key
      assert meta["kind"] == "chat"
    end

    test "an unknown original session id surfaces original_not_found", %{generation: generation} do
      assert {:error, :original_not_found} = Agents.create_follow_up("nope", generation)
    end

    test "no open workspace surfaces original_not_found" do
      Manager.close()
      assert {:error, :original_not_found} = Agents.create_follow_up("nope", 1)
    end

    test "a stale generation surfaces workspace_changed", %{
      ws: ws,
      generation: generation,
      alpha: alpha
    } do
      {:ok, %{id: original_id}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      on_exit(fn -> kill_session(original_id) end)

      assert {:error, :workspace_changed} =
               Agents.create_follow_up(original_id, generation - 1)
    end

    test "an unmounted ICM surfaces icm_unavailable; the original transcript stays viewable", %{
      ws: ws,
      generation: generation,
      alpha: alpha
    } do
      {:ok, %{id: original_id}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      kill_session(original_id)

      {:ok, _path} = Mounts.unmount(ws, alpha.mount_key)

      assert {:error, :icm_unavailable} = Agents.create_follow_up(original_id, generation)

      assert {:ok, %{status: "ended"}} = Agents.attach_or_replay(original_id)
    end
  end
end
