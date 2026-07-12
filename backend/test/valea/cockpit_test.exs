defmodule Valea.CockpitTest do
  # async: false — the new "mail" describe block below opens a real
  # workspace (`Valea.AgentCase.open_workspace!/1`), which drives the
  # process-global `Valea.Workspace.Manager` and a fixed `VALEA_APP_DIR` env
  # var; that can't safely interleave with another async test doing the same.
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mail.Index
  alias Valea.Mail.Message
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Engine
  alias Valea.Mounts
  alias Valea.Mounts.Manifest

  test "today returns the seeded narrative" do
    {:ok, today} = Valea.Cockpit.today()

    # Basic structure
    assert today["greeting"] == "Good morning, Mara."
    assert today["workspace"] == "Mara Lindt Coaching"
    assert String.starts_with?(today["date_label"], "Wednesday, 9 July")
    assert String.contains?(today["summary"], "Two sessions today")

    # Schedule
    assert length(today["schedule"]) == 4
    schedule = today["schedule"]
    assert Enum.at(schedule, 0)["time"] == "09:30"
    assert Enum.at(schedule, 0)["status"] == "current"
    assert Enum.at(schedule, 1)["time"] == "11:00"
    assert Enum.at(schedule, 1)["status"] == "prep_ready"
    assert Enum.at(schedule, 2)["time"] == "15:00"
    assert Enum.at(schedule, 2)["status"] == nil
    assert Enum.at(schedule, 3)["time"] == "16:30"
    assert Enum.at(schedule, 3)["status"] == "prep_at_14"

    # Prepared items
    assert length(today["prepared_items"]) == 3
    [priya, lea, julia] = today["prepared_items"]

    # Priya Nair - reply_drafted
    assert priya["type"] == "reply_drafted"
    assert priya["title"] == "Priya Nair · new inquiry"

    assert priya["summary"] ==
             "Good-fit inquiry — she asked about leadership coaching, which matches your core offer. Draft leads with the discovery call, not the price."

    assert priya["used_sources"] == [
             "her email",
             "Offers › Founder Coaching",
             "Tone guide",
             "Policies › No medical advice"
           ]

    assert priya["primary_action"] == "Review draft"
    assert priya["secondary_action"] == "Snooze"

    # Lea Brunner - prep_brief
    assert lea["type"] == "prep_brief"
    assert lea["title"] == "Lea Brunner · 11:00 session"

    assert lea["summary"] ==
             "One page from your approved notes: her homework was the pricing conversation with her first client; two open commitments from session 2."

    assert lea["used_sources"] == ["Clients › Lea", "session notes", "open commitments"]
    assert lea["primary_action"] == "Open brief"
    assert lea["secondary_action"] == "Snooze to 10:45"

    # Julia Steiner - follow_up_drafted
    assert julia["type"] == "follow_up_drafted"
    assert julia["title"] == "Julia Steiner · after Monday's session"

    assert julia["summary"] ==
             "Monday's session still has no follow-up. Drafted from your session notes: the two agreed next steps and the article you promised her."

    assert julia["used_sources"] == ["Clients › Julia", "session notes", "Tone guide"]
    assert julia["primary_action"] == "Review draft"
    assert julia["secondary_action"] == "Skip this one"

    # Open loops
    assert length(today["open_loops"]) == 4
    open_loops = today["open_loops"]

    assert Enum.at(open_loops, 0)["title"] == "Send proposal to Priya after the discovery call"
    assert Enum.at(open_loops, 0)["source"] == "from her email · yesterday"

    assert Enum.at(open_loops, 1)["title"] == "Give Feldmann a September workshop date"
    assert Enum.at(open_loops, 1)["source"] == "from Clients › Feldmann · open 3 weeks"

    assert Enum.at(open_loops, 2)["title"] == "Update the workshop page with the 2027 price"
    assert Enum.at(open_loops, 2)["source"] == "from Chat · yesterday"

    assert Enum.at(open_loops, 3)["title"] == "Reactivate 2 cold leads from May"
    assert Enum.at(open_loops, 3)["source"] == "from Weekly admin review workflow"

    # While you were away
    assert length(today["while_you_were_away"]) == 3
    away = today["while_you_were_away"]
    assert Enum.at(away, 0) == "Synced 9 emails from AI / Review · 7:00"
    assert Enum.at(away, 1) == "3 workflows ran: inquiry triage, session prep, receipt capture"
    assert Enum.at(away, 2) == "Moved 4 newsletters to Reading · Undo"

    # Mail — zero/unconfigured defaults: no workspace is open in this test,
    # so `Valea.Mail.Engine` isn't registered (Task 18).
    assert today["mail"] == %{"review_count" => 0, "inbox_count" => 0, "configured" => false}

    # Triage workflow path — no workspace is open in this test, so
    # `Valea.Workflows.list/0` finds nothing to discover (Task A-T13).
    assert today["triage_workflow_path"] == nil

    # Distill workflow path — same no-workspace-open reasoning (Task B8).
    assert today["distill_workflow_path"] == nil
  end

  describe "today/0 mail summary" do
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
          uid: nil,
          status: status,
          source: "imap",
          attachments: []
        })

      File.write!(abs, bytes)
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

      # The workspace template seeds ONE `status: review` message
      # (`sources/mail/messages/2026-07-09-priya-nair-seed0001.md`), indexed
      # on workspace open regardless of mail configuration — see
      # `test/valea_web/rpc_test.exs`'s identical assertion.
      assert today["mail"] == %{"review_count" => 1, "inbox_count" => 0, "configured" => false}
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
      {:ok, _count} = Index.rebuild(ws.path)

      Store.put_inbox_header(%{uid: 1, from_text: "Someone <a@b.com>", subject: "Hi", date: nil})
      Store.put_inbox_header(%{uid: 2, from_text: "Someone <c@d.com>", subject: "Yo", date: nil})

      Settings.write!(ws.path, %{
        account: "mara@example.com",
        # NOT `imap.example.com` — `Settings.load/1` treats that exact
        # string as the still-unset seed placeholder (`{:error,
        # :not_configured}`), same trap `mail_rpc_test.exs`'s own fixture
        # avoids.
        host: "imap.fastmail.com",
        port: 993,
        username: "mara@example.com"
      })

      :ok = Engine.reload_settings()

      {:ok, today} = Valea.Cockpit.today()

      # 2 = the seeded Priya message + the extra "review" message planted
      # above; the "processed" one doesn't count.
      assert today["mail"] == %{"review_count" => 2, "inbox_count" => 2, "configured" => true}
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

  describe "today/0 triage_workflow_path (Task A-T13: seeded-workflow discovery)" do
    defp write_mount!(ws_path, name, title) do
      dir = Path.join([ws_path, "mounts", name])
      File.mkdir_p!(dir)
      Manifest.write!(dir, %{id: "id-" <> name, name: title, description: ""})
      dir
    end

    defp write_triage_workflow!(mount_dir) do
      File.mkdir_p!(Path.join(mount_dir, "Workflows"))

      content = """
      ---
      enabled: true
      risk_level: medium
      ---
      # New Inquiry Triage

      Body.
      """

      File.write!(Path.join([mount_dir, "Workflows", "New Inquiry Triage.md"]), content)
    end

    test "carries the real mounts/<slug>/Workflows/... path from a freshly scaffolded workspace" do
      ws = AgentCase.open_workspace!()

      # T8's scaffold seeds the triage workflow in its one enabled starter
      # mount — named from the workspace's own name, slugified
      # (`Scaffold.mint_starter_mount!/2`), not necessarily literally
      # "starter" (`AgentCase.open_workspace!/1`'s default name "W" slugs
      # to "w").
      [mount] = Mounts.list(ws.path)

      {:ok, today} = Valea.Cockpit.today()

      assert today["triage_workflow_path"] ==
               "mounts/#{mount.name}/Workflows/New Inquiry Triage.md"
    end

    test "is nil when no enabled mount has a triage workflow" do
      ws = AgentCase.open_workspace!()

      # Disable the scaffold's own mount (which carries the seeded triage
      # workflow) so no enabled mount has one.
      Enum.each(Mounts.list(ws.path), &Mounts.set_enabled(&1.name, false))

      {:ok, today} = Valea.Cockpit.today()
      assert today["triage_workflow_path"] == nil
    end

    test "is found in a second mount when the first (alphabetically) enabled mount lacks one" do
      ws = AgentCase.open_workspace!()
      Enum.each(Mounts.list(ws.path), &Mounts.set_enabled(&1.name, false))

      write_mount!(ws.path, "aaa", "Mount AAA")
      # "aaa" sorts before "bbb" and has no Workflows/ at all.

      bbb = write_mount!(ws.path, "bbb", "Mount BBB")
      write_triage_workflow!(bbb)

      {:ok, today} = Valea.Cockpit.today()
      assert today["triage_workflow_path"] == "mounts/bbb/Workflows/New Inquiry Triage.md"
    end
  end

  describe "today/0 distill_workflow_path (Task B8: mirrors triage_workflow_path)" do
    defp write_distill_workflow!(mount_dir) do
      File.mkdir_p!(Path.join(mount_dir, "Workflows"))

      content = """
      ---
      enabled: true
      risk_level: medium
      ---
      # Distill Decisions

      Body.
      """

      File.write!(Path.join([mount_dir, "Workflows", "Distill Decisions.md"]), content)
    end

    test "is nil on a freshly scaffolded workspace (the starter-mount seed is Task B9's job)" do
      AgentCase.open_workspace!()

      {:ok, today} = Valea.Cockpit.today()
      assert today["distill_workflow_path"] == nil
    end

    test "carries the real mounts/<name>/Workflows/... path once an enabled mount has one" do
      ws = AgentCase.open_workspace!()
      Enum.each(Mounts.list(ws.path), &Mounts.set_enabled(&1.name, false))

      write_mount!(ws.path, "aaa", "Mount AAA")
      # "aaa" sorts before "bbb" and has no Workflows/ at all.

      bbb = write_mount!(ws.path, "bbb", "Mount BBB")
      write_distill_workflow!(bbb)

      {:ok, today} = Valea.Cockpit.today()
      assert today["distill_workflow_path"] == "mounts/bbb/Workflows/Distill Decisions.md"
    end
  end
end
