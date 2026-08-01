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
    only: [
      start_session: 3,
      kill_session: 1,
      mount_test_icm!: 2,
      open_workspace!: 1,
      fake_cmd: 1
    ]

  alias Valea.Api.Agents
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    ws = open_workspace!("W")
    icm = mount_test_icm!(ws.path, name: "Primary", pages: %{"CONTEXT.md" => "# Context\n"})
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

  # Scheduled-session visibility (tasks+schedules spec §Scheduled-session
  # visibility): the nav feed and the "Show all" pane EXCLUDE `kind:
  # "scheduled"` sessions unless the debug toggle asks for them, and the
  # filtering happens BACKEND-side (before the per-group take/page split), so
  # the store never fetches-then-hides.
  describe "include_scheduled" do
    defp write_scheduled_transcript!(ws, icm, id, kind) do
      dir = Path.join([ws, "logs", "sessions"])
      File.mkdir_p!(dir)

      meta = %{
        "schema" => "session/v1",
        "id" => id,
        "kind" => kind,
        "title" => "#{kind} session",
        "started_at" => "2026-07-29T08:00:00Z",
        "icm_mount" => icm.mount_key,
        "icm_name" => "Primary"
      }

      File.write!(Path.join(dir, id <> ".jsonl"), Jason.encode!(meta) <> "\n")
    end

    test "list_recent_sessions_by_icm hides scheduled runs by default", %{ws: ws, icm: icm} do
      write_scheduled_transcript!(ws, icm, "sess-chat", "chat")
      write_scheduled_transcript!(ws, icm, "sess-sched", "scheduled")

      assert {:ok, %{groups: [group]}} = run(:list_recent_sessions_by_icm, %{limit: 5})
      assert Enum.map(group.sessions, & &1.id) == ["sess-chat"]

      assert {:ok, %{groups: [group]}} =
               run(:list_recent_sessions_by_icm, %{limit: 5, include_scheduled: true})

      assert Enum.map(group.sessions, & &1.id) |> Enum.sort() == ["sess-chat", "sess-sched"]
    end

    test "an ICM whose only sessions are scheduled drops out of the grouped feed", %{
      ws: ws,
      icm: icm
    } do
      write_scheduled_transcript!(ws, icm, "sess-sched", "scheduled")

      assert {:ok, %{groups: []}} = run(:list_recent_sessions_by_icm, %{limit: 5})

      assert {:ok, %{groups: [_group]}} =
               run(:list_recent_sessions_by_icm, %{limit: 5, include_scheduled: true})
    end

    test "list_sessions_for hides scheduled runs by default", %{ws: ws, icm: icm} do
      write_scheduled_transcript!(ws, icm, "sess-chat", "chat")
      write_scheduled_transcript!(ws, icm, "sess-sched", "scheduled")

      assert {:ok, %{sessions: sessions}} =
               run(:list_sessions_for, %{mount_key: icm.mount_key, cursor: nil})

      assert Enum.map(sessions, & &1.id) == ["sess-chat"]

      assert {:ok, %{sessions: sessions}} =
               run(:list_sessions_for, %{
                 mount_key: icm.mount_key,
                 cursor: nil,
                 include_scheduled: true
               })

      assert length(sessions) == 2
    end
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

  # Spec 2026-08-02 — the session's ORIGIN. `opened_from_kind` arrives as a
  # client-supplied STRING and ends up as an ATOM on the scope, so the seam
  # between the two is a closed allowlist and never `String.to_atom/1`
  # (unbounded atom growth from a wire field is a DoS). It is doubly
  # load-bearing: `SessionSettings.opened_from_noun/1` has exactly three
  # clauses and no catch-all, so an unvetted atom reaching the scope would
  # raise inside `SessionScope.resolve/1` and break session LAUNCH, not
  # merely mislabel a premise. Both directions are covered here — the wire
  # argument on create, and the value read back off disk on resume (a
  # transcript is a file a user can hand-edit; it is untrusted input too).
  describe "opened_from_kind" do
    defp premise(ws, id) do
      path = Path.join([ws, "runtime", "sessions", id, "context.md"])
      if File.regular?(path), do: File.read!(path), else: ""
    end

    defp context_doc(icm), do: %{"kind" => "icm", "icm_id" => icm.id, "path" => "CONTEXT.md"}

    # Forget the materialized system prompt, so a later assertion on it can
    # only pass if the path under test re-wrote it.
    defp forget_context!(ws, id), do: File.rm_rf!(Path.join([ws, "runtime", "sessions", id]))

    defp end_session!(ws, id) do
      kill_session(id)
      wait_until(fn -> Registry.lookup(Valea.Agents.SessionRegistry, id) == [] end)
      forget_context!(ws, id)
    end

    defp tamper_meta!(ws, id, changes) do
      path = Path.join(ws, "logs/sessions/#{id}.jsonl")
      [meta | rest] = path |> File.read!() |> String.split("\n", trim: true)
      tampered = meta |> Jason.decode!() |> Map.merge(changes) |> Jason.encode!()
      File.write!(path, Enum.join([tampered | rest], "\n") <> "\n")
    end

    defp create_with_origin(generation, icm, kind) do
      Valea.App.Config.set_harness_command(fake_cmd("happy"))

      run(:create_session, %{
        mount_key: icm.mount_key,
        generation: generation,
        opened_from_kind: kind,
        context_doc: context_doc(icm)
      })
    end

    test "rejects an origin kind that is not in the allowlist — and creates no atom for it", %{
      generation: generation,
      icm: icm
    } do
      # NB `""` is deliberately absent: Ash's `:string` type trims and casts
      # an empty string to `nil` before the action's `run` ever sees it, so
      # a blank kind is "no origin", not a rejected one.
      for bogus <- ["../../etc/passwd", "mail-message", "Page", "workflow_run_kind_x"] do
        assert {:error, error} =
                 run(:create_session, %{
                   mount_key: icm.mount_key,
                   generation: generation,
                   opened_from_kind: bogus
                 })

        assert %Valea.Api.Error{code: "opened_from_kind_invalid"} = error.errors |> hd()

        # `String.to_existing_atom/1` raises for an atom the VM has never
        # seen — the assertion that the rejected string did NOT become one.
        assert_raise ArgumentError, fn -> String.to_existing_atom(bogus) end
      end
    end

    test "accepts the three real origin kinds and names the origin in the system prompt", %{
      ws: ws,
      generation: generation,
      icm: icm
    } do
      doc = Path.join(icm.root, "CONTEXT.md")

      for {kind, noun} <- [
            {"mail_message", "a mail message"},
            {"page", "a page in this ICM"},
            {"file", "a file in this ICM"}
          ] do
        assert {:ok, %{id: id}} = create_with_origin(generation, icm, kind)
        on_exit(fn -> kill_session(id) end)

        assert premise(ws, id) =~ "This session was opened from #{noun}: #{doc}."
        assert [meta | _] = transcript_lines(ws, id)
        assert Jason.decode!(meta)["opened_from_kind"] == kind
      end
    end

    test "a session created without an origin kind gets no premise paragraph", %{
      ws: ws,
      generation: generation,
      icm: icm
    } do
      Valea.App.Config.set_harness_command(fake_cmd("happy"))

      assert {:ok, %{id: id}} =
               run(:create_session, %{
                 mount_key: icm.mount_key,
                 generation: generation,
                 context_doc: context_doc(icm)
               })

      on_exit(fn -> kill_session(id) end)

      refute premise(ws, id) =~ "This session was opened from"
      assert [meta | _] = transcript_lines(ws, id)
      assert Jason.decode!(meta)["opened_from_kind"] == nil
    end

    test "resume rebuilds the origin from the recorded kind", %{
      ws: ws,
      generation: generation,
      icm: icm
    } do
      assert {:ok, %{id: id}} = create_with_origin(generation, icm, "page")
      end_session!(ws, id)

      assert {:ok, %{id: ^id}} =
               run(:resume_agent_session, %{session_id: id, generation: generation})

      on_exit(fn -> kill_session(id) end)

      assert premise(ws, id) =~
               "This session was opened from a page in this ICM: " <>
                 Path.join(icm.root, "CONTEXT.md")
    end

    test "resume drops the origin when the locator no longer resolves, without blocking", %{
      ws: ws,
      generation: generation,
      icm: icm
    } do
      assert {:ok, %{id: id}} = create_with_origin(generation, icm, "page")
      end_session!(ws, id)
      File.rm!(Path.join(icm.root, "CONTEXT.md"))

      assert {:ok, %{id: ^id}} =
               run(:resume_agent_session, %{session_id: id, generation: generation})

      on_exit(fn -> kill_session(id) end)

      # Narrowed, not blocked: a resumed session never names a path it can
      # no longer read.
      refute premise(ws, id) =~ "This session was opened from"
    end

    test "resume treats a hand-edited origin kind as untrusted input", %{
      ws: ws,
      generation: generation,
      icm: icm
    } do
      assert {:ok, %{id: id}} = create_with_origin(generation, icm, "page")
      end_session!(ws, id)
      tamper_meta!(ws, id, %{"opened_from_kind" => "hand_edited_origin_kind"})

      # No FunctionClauseError out of `SessionSettings.opened_from_noun/1`
      # (which would break the resume outright), no premise, no new atom.
      assert {:ok, %{id: ^id}} =
               run(:resume_agent_session, %{session_id: id, generation: generation})

      on_exit(fn -> kill_session(id) end)

      refute premise(ws, id) =~ "This session was opened from"
      assert_raise ArgumentError, fn -> String.to_existing_atom("hand_edited_origin_kind") end
    end

    test "resume ignores a non-string origin kind in the transcript", %{
      ws: ws,
      generation: generation,
      icm: icm
    } do
      assert {:ok, %{id: id}} = create_with_origin(generation, icm, "page")
      end_session!(ws, id)
      tamper_meta!(ws, id, %{"opened_from_kind" => %{"kind" => "page"}})

      assert {:ok, %{id: ^id}} =
               run(:resume_agent_session, %{session_id: id, generation: generation})

      on_exit(fn -> kill_session(id) end)

      refute premise(ws, id) =~ "This session was opened from"
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
