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

    # icm_name (Task 9.5) — no workspace is open in this test, so
    # `seed_icm_name/0` has no triage workflow to derive an owning ICM
    # from (same no-workspace-open reasoning as triage_workflow_path).
    assert priya["icm_name"] == nil
    assert lea["icm_name"] == nil
    assert julia["icm_name"] == nil

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

    # `Valea.Mounts.list/1` is config truth over `icms:` ONLY — a freshly
    # scaffolded (v5) workspace carries no seeded mount at all, so every
    # mount in this describe block is a REAL EXTERNAL ICM, mounted via
    # `AgentCase.mount_test_icm!/2`, and every expected workflow path is
    # that ICM's ABSOLUTE resolved path — never a `mounts/<name>/...`
    # workspace-relative literal.
    test "carries the real absolute Workflows/... path from a mounted external ICM" do
      ws = AgentCase.open_workspace!()

      icm =
        AgentCase.mount_test_icm!(ws.path,
          name: "Primary",
          pages: %{
            "Workflows/New Inquiry Triage.md" => """
            ---
            enabled: true
            risk_level: medium
            ---
            # New Inquiry Triage

            Body.
            """
          }
        )

      {:ok, today} = Valea.Cockpit.today()

      assert today["triage_workflow_path"] ==
               Path.join(icm.root, "Workflows/New Inquiry Triage.md")
    end

    test "is nil when no enabled mount has a triage workflow" do
      ws = AgentCase.open_workspace!()
      AgentCase.mount_test_icm!(ws.path, name: "Empty")

      {:ok, today} = Valea.Cockpit.today()
      assert today["triage_workflow_path"] == nil
    end

    test "is found in a second mount when the first (alphabetically) enabled mount lacks one" do
      ws = AgentCase.open_workspace!()
      # "aaa" sorts before "bbb" (mount keys are the slugified display
      # name) and has no Workflows/ at all.
      AgentCase.mount_test_icm!(ws.path, name: "aaa")
      bbb = AgentCase.mount_test_icm!(ws.path, name: "bbb")
      write_triage_workflow!(bbb.root)

      {:ok, today} = Valea.Cockpit.today()

      assert today["triage_workflow_path"] ==
               Path.join(bbb.root, "Workflows/New Inquiry Triage.md")
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

    # Task B9's promise ("a freshly scaffolded workspace already has the
    # Distill workflow available, no explicit action needed") depended on
    # the legacy v4 scaffold auto-seeding ONE starter mount. Post-3.2 a
    # fresh v5 workspace has NO default `icms:` entry at all (config
    # truth, nothing implicit) — the equivalent promise now lives one
    # layer up, at `Valea.Mounts.create/3` (task 3.5): every ICM created
    # through the app's normal create flow is seeded from
    # `priv/icm_template/`, which carries `Workflows/Distill Decisions.md`
    # out of the box. This test asserts THAT promise instead.
    test "carries the seeded path once an ICM is created via Mounts.create/3 (Task B9 promise, relocated to create/3 + icm_template)" do
      ws = AgentCase.open_workspace!()

      target =
        Path.join(
          System.tmp_dir!(),
          "valea-cockpit-distill-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(target) end)

      {:ok, %{mount_key: mount_key}} = Mounts.create(ws.path, "W", target)
      created = Mounts.mount_by_key(ws.path, mount_key)

      {:ok, today} = Valea.Cockpit.today()

      assert today["distill_workflow_path"] ==
               Path.join(created.root, "Workflows/Distill Decisions.md")
    end

    test "carries the real absolute Workflows/... path once an enabled mount has one" do
      ws = AgentCase.open_workspace!()
      AgentCase.mount_test_icm!(ws.path, name: "aaa")
      bbb = AgentCase.mount_test_icm!(ws.path, name: "bbb")
      write_distill_workflow!(bbb.root)

      {:ok, today} = Valea.Cockpit.today()

      assert today["distill_workflow_path"] ==
               Path.join(bbb.root, "Workflows/Distill Decisions.md")
    end
  end

  describe "today/0 prepared_items icm_name (Task 9.5: seeded-item ICM provenance)" do
    test "is nil on every prepared item when no enabled mount has a triage workflow" do
      ws = AgentCase.open_workspace!()
      AgentCase.mount_test_icm!(ws.path, name: "Empty")

      {:ok, today} = Valea.Cockpit.today()

      assert Enum.map(today["prepared_items"], & &1["icm_name"]) == [nil, nil, nil]
    end

    # Post-3.2, a mount's config-truth `mount_key` need not equal its
    # manifest display `name` — `mount_test_icm!/2`'s `name:` opt controls
    # ONLY the manifest (icm.yaml `name:`), never the derived mount_key, so
    # asserting `icm_name` (the manifest's own display name) rather than
    # `mount_key` here is the one honest way to distinguish this field
    # from `triage_workflow_mount_key`'s own assertions above.
    test "carries the triage workflow's owning mount's manifest display name on every prepared item" do
      ws = AgentCase.open_workspace!()

      icm =
        AgentCase.mount_test_icm!(ws.path,
          name: "Mara Lindt Coaching",
          pages: %{
            "Workflows/New Inquiry Triage.md" => """
            ---
            enabled: true
            risk_level: medium
            ---
            # New Inquiry Triage

            Body.
            """
          }
        )

      {:ok, today} = Valea.Cockpit.today()

      assert today["triage_workflow_mount_key"] == icm.mount_key

      assert Enum.map(today["prepared_items"], & &1["icm_name"]) == [
               "Mara Lindt Coaching",
               "Mara Lindt Coaching",
               "Mara Lindt Coaching"
             ]
    end
  end
end
