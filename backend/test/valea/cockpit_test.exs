defmodule Valea.CockpitTest do
  # async: false — the "mail" describe block below opens a real workspace
  # (`Valea.AgentCase.open_workspace!/1`), which drives the process-global
  # `Valea.Workspace.Manager` and a fixed `VALEA_APP_DIR` env var; that can't
  # safely interleave with another async test doing the same.
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mail.Message
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Engine
  alias Valea.Mounts

  describe "today/0 sections" do
    test "no workspace open → empty sections, zero mail, empty recent_sessions" do
      {:ok, today} = Valea.Cockpit.today()
      assert today["sections"] == []
      assert today["recent_sessions"] == []
      assert today["mail"] == %{"review_count" => 0, "inbox_count" => 0, "configured" => false}
    end

    test "enabled ICM without today.json contributes no section" do
      ws = AgentCase.open_workspace!()
      AgentCase.mount_test_icm!(ws.path, name: "Primary")

      {:ok, today} = Valea.Cockpit.today()
      assert today["sections"] == []
    end

    test "valid today.json becomes a section with provenance" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Mara Lindt Coaching")

      File.write!(Path.join(icm.root, "today.json"), ~s({
        "updated_at": "2026-07-16T08:00:00Z",
        "prepared": [{"title": "Prep Lea", "summary": "One page", "page": "clients/lea.md"}],
        "open_loops": [{"title": "Send proposal", "source": "mail"}],
        "notes": "Quiet day.",
        "unknown_field": {"ignored": true}
      }))

      {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
      assert section["mount_key"] == icm.mount_key
      assert section["icm_name"] == "Mara Lindt Coaching"
      assert section["ok"] == true
      assert section["updated_at"] == "2026-07-16T08:00:00Z"
      assert section["notes"] == "Quiet day."

      assert section["prepared"] == [
               %{"title" => "Prep Lea", "summary" => "One page", "page" => "clients/lea.md"}
             ]

      assert section["open_loops"] == [%{"title" => "Send proposal", "source" => "mail"}]
      refute Map.has_key?(section, "unknown_field")
    end

    test "malformed JSON → ok false section, never an error" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
      File.write!(Path.join(icm.root, "today.json"), "{not json")

      {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
      assert section["ok"] == false
      assert section["prepared"] == []
      assert section["open_loops"] == []
    end

    test "lenient field handling: wrong types dropped to nil/[]" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

      File.write!(Path.join(icm.root, "today.json"), ~s({
        "updated_at": 42,
        "prepared": [{"title": "ok", "summary": 7}, "not-a-map"],
        "open_loops": "nope",
        "notes": ["x"]
      }))

      {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
      assert section["ok"] == true
      assert section["updated_at"] == nil
      assert section["notes"] == nil
      assert section["prepared"] == [%{"title" => "ok", "summary" => nil, "page" => nil}]
      assert section["open_loops"] == []
    end

    test "disabled mount contributes no section; order follows Mounts.enabled/0" do
      ws = AgentCase.open_workspace!()
      # Mounted in reverse-alphabetical order so a passing "config order"
      # assertion can't be an accident of insertion order — see the identical
      # reasoning in `test/valea/agents_test.exs`'s `setup` block.
      bbb = AgentCase.mount_test_icm!(ws.path, name: "bbb")
      aaa = AgentCase.mount_test_icm!(ws.path, name: "aaa")

      File.write!(Path.join(aaa.root, "today.json"), ~s({"notes": "A"}))
      File.write!(Path.join(bbb.root, "today.json"), ~s({"notes": "B"}))

      :ok = Mounts.set_enabled(ws.path, bbb.mount_key, false)

      {:ok, %{"sections" => [only]}} = Valea.Cockpit.today()
      assert only["mount_key"] == aaa.mount_key

      :ok = Mounts.set_enabled(ws.path, bbb.mount_key, true)

      {:ok, %{"sections" => sections}} = Valea.Cockpit.today()
      {:ok, enabled_mounts} = Mounts.enabled()
      assert Enum.map(sections, & &1["mount_key"]) == Enum.map(enabled_mounts, & &1.name)
    end
  end

  describe "today/0 recent_sessions" do
    # Mirrors `write_transcript!/4` in `test/valea/agents_test.exs`, trimmed
    # to only the fields `Valea.Agents.session_summary/1` actually reads for
    # this cap/order/trim contract — a real session-launch fixture (the
    # `AgentCase.start_session/3` harness path) is unnecessary weight here.
    defp write_session_meta!(workspace, id, started_at) do
      dir = Path.join([workspace, "logs", "sessions"])
      File.mkdir_p!(dir)

      meta = %{
        "schema" => "session/v1",
        "id" => id,
        "title" => "Test session #{id}",
        "started_at" => started_at
      }

      File.write!(Path.join(dir, id <> ".jsonl"), Jason.encode!(meta) <> "\n")
    end

    defp iso(seconds_offset) do
      ~U[2026-01-01 00:00:00Z] |> DateTime.add(seconds_offset, :second) |> DateTime.to_iso8601()
    end

    test "no sessions → []" do
      AgentCase.open_workspace!()
      {:ok, today} = Valea.Cockpit.today()
      assert today["recent_sessions"] == []
    end

    test "newest-first, capped at 5, trimmed fields" do
      ws = AgentCase.open_workspace!()

      for i <- 1..6 do
        write_session_meta!(ws.path, "session-#{i}", iso(i))
      end

      {:ok, %{"recent_sessions" => recent}} = Valea.Cockpit.today()
      assert length(recent) == 5
      assert List.first(recent)["started_at"] > List.last(recent)["started_at"]

      assert Map.keys(List.first(recent)) |> Enum.sort() ==
               ["id", "live", "started_at", "status", "title"]
    end
  end

  describe "today/0 mail summary" do
    # TEMP v3-bridge test adaptation (Task 6): see the identical comment on
    # `mail_rpc_test.exs`'s `plant_message/3` — `MessageFile.render/2`'s meta
    # shape lost `uid`/`status`/`source`, and `Index.rebuild/1` no longer
    # indexes this flat legacy layout. `Valea.Cockpit.mail_summary/0` still
    # reads the OLD `Store.upsert_message/1`-keyed cache via
    # `Store.list_messages/0` (rewritten in Task 10), so this helper writes
    # the file (for parity with the on-disk shape) and seeds that cache row
    # directly instead of relying on `Index.rebuild/1`.
    defp plant_message(root, suffix, status) do
      msg_id = "2026-07-09-priya-#{suffix}"
      rel = Path.join(["sources", "mail", "messages", "#{msg_id}.md"])
      abs = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(abs))

      message = %Message{
        message_id: "<orig-#{suffix}@mail.example.com>",
        from: %{name: "Priya Nair", email: "priya@example.com"},
        subject: "Inquiry",
        date: ~U[2026-07-09 10:00:00Z],
        body_text: "Body.\n"
      }

      bytes =
        MessageFile.render(message, %{
          msg_id: msg_id,
          account: "mara@example.com",
          folders: ["INBOX"],
          flags: "",
          attachments: []
        })

      File.write!(abs, bytes)

      :ok =
        Store.upsert_message(%{
          msg_id: msg_id,
          message_id: message.message_id,
          path: rel,
          from: message.from,
          subject: message.subject,
          date: message.date,
          status: status,
          has_attachments: false,
          uid: nil
        })
    end

    # `AgentCase.open_workspace!/1` returns as soon as `Manager.create/2`
    # does — it does NOT wait for `Valea.Mail.Engine` to finish processing
    # the `:workspace_opened` broadcast it reacts to asynchronously (its own
    # mailbox, a separate process). Activation is where `Index.rebuild/1`
    # actually runs (see `engine.ex`'s `activate/1`), so a test that reads
    # `Store.list_messages/0` immediately after opening can race an engine
    # that's still "inactive". Polling `status().state` past `"inactive"`
    # is a synchronization point: `state.status` only flips off
    # `"inactive"` at the END of `activate/1`, strictly after its
    # `Index.rebuild/1` call, so by the time this returns, indexing is done.
    defp await_engine_active! do
      Enum.reduce_while(1..200, nil, fn _, _ ->
        case Engine.status() do
          %{state: "inactive"} ->
            Process.sleep(5)
            {:cont, nil}

          status ->
            {:halt, status}
        end
      end)
    end

    test "reports zero/unconfigured defaults when the engine is active but not yet configured" do
      AgentCase.open_workspace!()
      await_engine_active!()

      {:ok, today} = Valea.Cockpit.today()

      # The v4 workspace template ships `accounts: {}` and no seed message
      # (mail design spec E) — zero review/inbox counts until a real account
      # syncs. See `test/valea_web/rpc_test.exs`'s identical assertion.
      assert today["mail"] == %{"review_count" => 0, "inbox_count" => 0, "configured" => false}
    end

    test "reports live review/inbox counts once the account is configured" do
      ws = AgentCase.open_workspace!()
      # Required, not just belt-and-braces: `mail_summary/0` now reports the
      # deterministic zero shape while the Engine is still `"inactive"`, so
      # reading `today/0` before activation would fail this test's live-count
      # assertion regardless of what the Store already contains.
      await_engine_active!()

      plant_message(ws.path, "extra-review", "review")
      plant_message(ws.path, "extra-processed", "processed")

      Store.put_inbox_header(%{uid: 1, from_text: "Someone <a@b.com>", subject: "Hi", date: nil})
      Store.put_inbox_header(%{uid: 2, from_text: "Someone <c@d.com>", subject: "Yo", date: nil})

      :ok =
        Settings.upsert_account!(ws.path, "mara", %{
          host: "imap.fastmail.com",
          port: 993,
          username: "mara@example.com"
        })

      :ok = Engine.reload_settings()

      {:ok, today} = Valea.Cockpit.today()

      # 1 = only the extra "review" message planted above (the v4 workspace
      # template ships no seed message, mail design spec E); the
      # "processed" one doesn't count.
      assert today["mail"] == %{"review_count" => 1, "inbox_count" => 2, "configured" => true}
    end

    test "degrades to the zero summary when the Repo is down but the Engine is still registered" do
      AgentCase.open_workspace!()
      await_engine_active!()

      # The exact window `Valea.Workspace.Manager.do_close/1` opens on every
      # close/switch: `state.children` is `[repo_pid, runtime_pid]`,
      # terminated in list order, so the Repo dies FIRST while the Engine (a
      # Runtime child) is still registered. Reproduce it directly by
      # terminating the Repo child; `Valea.Workspace.DynamicSupervisor` never
      # restarts a child it was asked to terminate, so the window stays open
      # for the assertion below.
      repo_pid = Process.whereis(Valea.Repo)
      assert is_pid(repo_pid)
      :ok = DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, repo_pid)

      assert Process.whereis(Valea.Mail.Engine)

      # Must not raise/exit despite `Store.list_messages/0` hitting a dead
      # Repo — `live_mail_summary/0`'s rescue degrades to the zero shape.
      {:ok, today} = Valea.Cockpit.today()

      assert today["mail"] == %{"review_count" => 0, "inbox_count" => 0, "configured" => false}
    end
  end
end
