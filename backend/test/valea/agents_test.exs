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

  defp write_transcript!(workspace, id, mount_key, started_at, kind \\ "chat") do
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
      "kind" => kind,
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

    # The scheduled-run filter runs BEFORE `Enum.take(limit)`, and this is the
    # test that pins it: with the two NEWEST sessions scheduled, filtering after
    # the take would return an EMPTY group (or a short one) while `limit` was
    # spent on rows the caller asked not to see. `limit` means "limit the rows I
    # get", not "limit the rows you looked at".
    test "the scheduled filter runs before the limit — a full group of chat sessions",
         %{ws: ws, alpha: alpha} do
      write_transcript!(ws, "chat-old", alpha.mount_key, iso(1))
      write_transcript!(ws, "chat-new", alpha.mount_key, iso(2))
      write_transcript!(ws, "sched-1", alpha.mount_key, iso(3), "scheduled")
      write_transcript!(ws, "sched-2", alpha.mount_key, iso(4), "scheduled")

      assert [%{sessions: sessions}] = Agents.list_recent_sessions_by_icm(2)
      assert Enum.map(sessions, & &1.id) == ["chat-new", "chat-old"]

      assert [%{sessions: all}] =
               Agents.list_recent_sessions_by_icm(2, include_scheduled: true)

      assert Enum.map(all, & &1.id) == ["sched-2", "sched-1"]
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

    # The same before-vs-after question as the grouped feed, with paging's
    # sharper failure mode: filtering AFTER `Enum.split/2` returns a SHORT page
    # AND derives `next_cursor` from a row the caller never saw — so the next
    # call resumes from a filtered-out id and the sessions between them are
    # skipped for good. Interleaved kinds with page_size 2: a full page of two
    # chat rows, and a cursor that resolves to the remainder.
    test "the scheduled filter runs before the page split — full pages, cursor stays resolvable",
         %{ws: ws, alpha: alpha} do
      write_transcript!(ws, "chat-1", alpha.mount_key, iso(1))
      write_transcript!(ws, "chat-2", alpha.mount_key, iso(2))
      write_transcript!(ws, "sched-3", alpha.mount_key, iso(3), "scheduled")
      write_transcript!(ws, "chat-4", alpha.mount_key, iso(4))
      write_transcript!(ws, "sched-5", alpha.mount_key, iso(5), "scheduled")

      assert %{sessions: page1, next_cursor: cursor} =
               Agents.list_sessions_for(alpha.mount_key, nil, page_size: 2)

      assert Enum.map(page1, & &1.id) == ["chat-4", "chat-2"]
      assert cursor == "chat-2"

      assert %{sessions: page2, next_cursor: nil} =
               Agents.list_sessions_for(alpha.mount_key, cursor, page_size: 2)

      assert Enum.map(page2, & &1.id) == ["chat-1"]

      # And with the toggle on, the same traversal sees every kind.
      assert %{sessions: all, next_cursor: all_cursor} =
               Agents.list_sessions_for(alpha.mount_key, nil,
                 page_size: 2,
                 include_scheduled: true
               )

      assert Enum.map(all, & &1.id) == ["sched-5", "chat-4"]
      assert all_cursor == "chat-4"
    end

    defp fetch_page(mount_key, cursor) do
      %{sessions: sessions, next_cursor: next_cursor} =
        Agents.list_sessions_for(mount_key, cursor, page_size: 10)

      {Enum.map(sessions, & &1.id), next_cursor}
    end
  end

  describe "session_meta/1 + resume_session/1" do
    test "session_meta returns the transcript's line-1 identity; unknown/traversal ids are not_found",
         %{ws: ws, alpha: alpha} do
      {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      on_exit(fn -> kill_session(id) end)

      assert {:ok, meta} = Agents.session_meta(id)
      assert meta["icm_mount"] == alpha.mount_key
      assert meta["kind"] == "chat"

      assert {:error, :not_found} = Agents.session_meta("nope")
      assert {:error, :not_found} = Agents.session_meta("../secrets")
    end

    test "session_meta is not_found with no open workspace" do
      Manager.close()
      assert {:error, :not_found} = Agents.session_meta("nope")
    end

    test "resume_session revives an ended session in the SAME transcript, seq continuing after the history",
         %{ws: ws, generation: generation, alpha: alpha} do
      {:ok, %{id: id}} = start_session(ws, "happy", %{mount_key: alpha.mount_key})
      kill_session(id)
      wait_until(fn -> Registry.lookup(Valea.Agents.SessionRegistry, id) == [] end)

      path = Path.join(ws, "logs/sessions/#{id}.jsonl")
      lines_before = path |> File.read!() |> String.split("\n", trim: true)
      {:ok, %{cursor: cursor_before}} = Agents.attach_or_replay(id)

      {:ok, meta} = Agents.session_meta(id)

      {:ok, scope} =
        Valea.Agents.SessionScope.resolve(%{
          kind: "chat",
          mount_key: meta["icm_mount"],
          generation: generation,
          session_id: id
        })

      assert {:ok, %{id: ^id}} = Agents.resume_session(%{id: id, scope: scope, meta: meta})
      on_exit(fn -> kill_session(id) end)

      # Same file, identity line untouched, nothing lost.
      lines_after = path |> File.read!() |> String.split("\n", trim: true)
      assert hd(lines_after) == hd(lines_before)

      # Live attach again, snapshot seeded with the pre-resume history and
      # a cursor that CONTINUES from it (the channel's seq gate stays
      # monotonic across the revival).
      assert {:ok, %{cursor: cursor, status: status}} = Agents.attach_or_replay(id)
      assert cursor >= cursor_before
      assert status in ["starting", "running"]

      # Idempotent by goal state while live.
      assert {:ok, %{id: ^id}} = Agents.resume_session(%{id: id, scope: scope, meta: meta})
    end

    # The registry value is what "is a session already working on this file?"
    # is answered from (`list_running_session_inputs/0`). A resume that
    # dropped it would silently break that correlation for exactly the
    # sessions most likely to be asked about — the ones a user came back to.
    test "a resumed session re-registers the input locator its transcript recorded",
         %{ws: ws, generation: generation, alpha: alpha} do
      locator = %{"kind" => "workspace", "path" => "sources/notes/msg.md"}

      {:ok, %{id: id}} =
        start_session(ws, "happy", %{mount_key: alpha.mount_key, input: locator})

      kill_session(id)
      wait_until(fn -> Registry.lookup(Valea.Agents.SessionRegistry, id) == [] end)

      {:ok, meta} = Agents.session_meta(id)
      assert meta["input"] == locator

      {:ok, scope} =
        Valea.Agents.SessionScope.resolve(%{
          kind: "chat",
          mount_key: meta["icm_mount"],
          generation: generation,
          session_id: id
        })

      assert {:ok, %{id: ^id}} = Agents.resume_session(%{id: id, scope: scope, meta: meta})
      on_exit(fn -> kill_session(id) end)

      assert {^id, ^locator} =
               Agents.list_running_session_inputs() |> Enum.find(&(elem(&1, 0) == id))
    end
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
end
