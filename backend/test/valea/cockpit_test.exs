defmodule Valea.CockpitTest do
  # async: false — the "mail" describe block below opens a real workspace
  # (`Valea.AgentCase.open_workspace!/1`), which drives the process-global
  # `Valea.Workspace.Manager` and a fixed `VALEA_APP_DIR` env var; that can't
  # safely interleave with another async test doing the same.
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mail.Engine
  alias Valea.Mail.Settings
  alias Valea.Mail.Supervisor, as: MailSupervisor
  alias Valea.Mounts
  alias Valea.Schedules.Store

  describe "today/0 sections" do
    test "no workspace open → empty sections, empty mail, empty recent_sessions" do
      {:ok, today} = Valea.Cockpit.today()
      assert today["sections"] == []
      assert today["recent_sessions"] == []
      assert today["mail"] == []
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

      # `open_loops` is GONE (tasks+schedules spec §UI surfaces → Cockpit): the
      # tasks line off `tasks.json` replaces it, and `today.json`'s own
      # `open_loops` array — which agents may still carry — is now an unknown
      # field like any other, ignored rather than surfaced.
      refute Map.has_key?(section, "open_loops")
      refute Map.has_key?(section, "unknown_field")
    end

    test "malformed JSON → ok false section, never an error" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
      File.write!(Path.join(icm.root, "today.json"), "{not json")

      {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
      assert section["ok"] == false
      assert section["prepared"] == []
      refute Map.has_key?(section, "open_loops")
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
      refute Map.has_key?(section, "open_loops")
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
      # Sections are ICM content only — `enabled/0` also carries the
      # synthetic calendar mount (Spec F Task 5), which never sections.
      icm_mounts = Enum.filter(enabled_mounts, &(&1.kind == :icm))
      assert Enum.map(sections, & &1["mount_key"]) == Enum.map(icm_mounts, & &1.name)
    end
  end

  # The tasks line replacing `open_loops` (tasks+schedules spec §UI surfaces →
  # Cockpit): counts + the top 3, read off the ICM's own `tasks.json` — a file
  # INDEPENDENT of `today.json`, so its failures degrade on their own (the
  # `mail_summary/0` posture: a broken task ledger never kills the section).
  describe "today/0 tasks line" do
    # Host-zone dates, through the SAME zone source the calendar line uses:
    # "due today" is a wall-clock question, and a UTC-vs-host boundary is
    # exactly the bug this pins wherever the suite runs.
    defp host_today do
      {:ok, local} = DateTime.now(Valea.Calendar.Engine.host_zone())
      DateTime.to_date(local)
    end

    defp iso_date(offset_days), do: host_today() |> Date.add(offset_days) |> Date.to_iso8601()

    defp write_tasks!(icm, tasks) do
      File.write!(Path.join(icm.root, "tasks.json"), Jason.encode!(%{"tasks" => tasks}))
    end

    defp section_with_today!(icm) do
      File.write!(Path.join(icm.root, "today.json"), ~s({"notes": "n"}))
      {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
      section
    end

    test "counts due today / overdue / in_progress in the HOST zone, completed excluded" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

      write_tasks!(icm, [
        %{"id" => "t-1", "title" => "due today", "status" => "open", "due" => iso_date(0)},
        %{"id" => "t-2", "title" => "overdue", "status" => "open", "due" => iso_date(-3)},
        %{"id" => "t-3", "title" => "future", "status" => "open", "due" => iso_date(5)},
        %{"id" => "t-4", "title" => "working", "status" => "in_progress"},
        # Completed entries never count, whatever their due date says.
        %{"id" => "t-5", "title" => "done today", "status" => "done", "due" => iso_date(0)},
        %{
          "id" => "t-6",
          "title" => "dropped overdue",
          "status" => "dropped",
          "due" => iso_date(-1)
        },
        # Lenient: an unparseable due is simply not a date.
        %{"id" => "t-7", "title" => "junk due", "status" => "open", "due" => "whenever"}
      ])

      assert %{"due_today" => 1, "overdue" => 1, "in_progress" => 1} =
               section_with_today!(icm)["tasks"]
    end

    test "top is 3 items: today-flag first, then due asc, then priority" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

      write_tasks!(icm, [
        %{"id" => "t-low", "title" => "low, no due", "status" => "open", "priority" => "low"},
        %{"id" => "t-high", "title" => "high, no due", "status" => "open", "priority" => "high"},
        %{
          "id" => "t-med",
          "title" => "medium, no due",
          "status" => "open",
          "priority" => "medium"
        },
        %{"id" => "t-soon", "title" => "due tomorrow", "status" => "open", "due" => iso_date(1)},
        %{"id" => "t-flag", "title" => "flagged", "status" => "open", "today" => true},
        %{"id" => "t-done", "title" => "completed", "status" => "done", "today" => true}
      ])

      assert %{"top" => top} = section_with_today!(icm)["tasks"]
      assert Enum.map(top, & &1["id"]) == ["t-flag", "t-soon", "t-high"]

      assert hd(top) == %{
               "id" => "t-flag",
               "title" => "flagged",
               "due" => nil,
               "today" => true,
               "priority" => nil
             }
    end

    test "absent tasks.json → a zeroed line, not nil" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

      assert section_with_today!(icm)["tasks"] == %{
               "due_today" => 0,
               "overdue" => 0,
               "in_progress" => 0,
               "top" => []
             }
    end

    test "malformed tasks.json → tasks nil, section stays ok" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
      File.write!(Path.join(icm.root, "tasks.json"), "{not json")

      section = section_with_today!(icm)
      assert section["ok"] == true
      assert section["tasks"] == nil
    end

    test "a section for an unreadable today.json still carries its tasks line" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
      File.write!(Path.join(icm.root, "today.json"), "{not json")
      write_tasks!(icm, [%{"id" => "t-1", "title" => "x", "status" => "in_progress"}])

      {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
      assert section["ok"] == false
      assert section["tasks"]["in_progress"] == 1
    end
  end

  # Notices ONLY for schedules (spec §UI surfaces → Cockpit): parked run,
  # failed run, newly registered schedule — nothing else, and never any
  # captured output (that lives behind the run-history RPC, capped).
  describe "today/0 schedule_notices" do
    defp write_schedules!(icm, schedules) do
      File.write!(
        Path.join(icm.root, "schedules.json"),
        Jason.encode!(%{"schedules" => schedules})
      )
    end

    defp notice(notices, schedule_id) do
      Enum.find(notices, &(&1["schedule_id"] == schedule_id))
    end

    test "no workspace open → []" do
      {:ok, today} = Valea.Cockpit.today()
      assert today["schedule_notices"] == []
    end

    test "a fresh workspace with nothing scheduled → []" do
      AgentCase.open_workspace!()
      {:ok, today} = Valea.Cockpit.today()
      assert today["schedule_notices"] == []
    end

    test "failed and registered notices carry kind/mount_key/schedule_id/title/at, no output" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

      write_schedules!(icm, [
        %{
          "id" => "s-brief",
          "title" => "Morning brief",
          "cron" => "30 7 * * 1-5",
          "payload" => %{"kind" => "prompt", "prompt" => "go"}
        }
      ])

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _run} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-brief",
          fingerprint: "fp",
          slot: DateTime.add(now, -120, :second),
          fired_at: DateTime.add(now, -60, :second),
          trigger: "scheduled",
          kind: "command",
          outcome: "failed",
          output: "SECRET OUTPUT",
          mount_key: icm.mount_key
        })

      :ok =
        Store.put_state(icm.id, "s-brief", %{
          fingerprint: "fp",
          first_seen_at: DateTime.add(now, -30, :second),
          last_attempted_slot: now
        })

      {:ok, %{"schedule_notices" => notices}} = Valea.Cockpit.today()

      kinds = notices |> Enum.filter(&(&1["schedule_id"] == "s-brief")) |> Enum.map(& &1["kind"])
      assert "failed" in kinds
      assert "registered" in kinds

      failed = Enum.find(notices, &(&1["kind"] == "failed"))
      assert failed["mount_key"] == icm.mount_key
      assert failed["title"] == "Morning brief"
      assert is_binary(failed["at"])
      assert Map.keys(failed) |> Enum.sort() == ~w(at kind mount_key schedule_id title)
      refute Jason.encode!(notices) =~ "SECRET OUTPUT"
    end

    test "events older than 24h are not notices" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
      write_schedules!(icm, [])

      old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)

      {:ok, _run} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-old",
          fingerprint: "fp",
          slot: old,
          fired_at: old,
          trigger: "scheduled",
          kind: "command",
          outcome: "failed",
          mount_key: icm.mount_key
        })

      :ok = Store.put_state(icm.id, "s-old", %{fingerprint: "fp", first_seen_at: old})

      {:ok, %{"schedule_notices" => notices}} = Valea.Cockpit.today()
      assert notice(notices, "s-old") == nil
    end

    test "a run recorded running is NOT a waiting notice while its session is gone" do
      ws = AgentCase.open_workspace!()
      icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
      write_schedules!(icm, [])

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _run} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-prompt",
          fingerprint: "fp",
          slot: now,
          fired_at: now,
          trigger: "scheduled",
          kind: "prompt",
          outcome: "running",
          session_id: "sess-that-never-existed",
          mount_key: icm.mount_key
        })

      {:ok, %{"schedule_notices" => notices}} = Valea.Cockpit.today()
      assert notice(notices, "s-prompt") == nil

      # And the store still says "running" — `waiting` is a projection, never
      # a persisted outcome (the `running_runs/1` literal-match contract).
      assert [%{outcome: "running"}] = Store.running_runs(icm_id: icm.id)
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
    defp setup_account!(root, slug, host \\ "imap.fastmail.com") do
      :ok =
        Settings.upsert_account!(root, slug, %{
          host: host,
          port: 993,
          username: "#{slug}@example.com"
        })

      :ok = MailSupervisor.reload_settings_all(root)
    end

    # A fresh account's Engine self-activates immediately when started via
    # `reload_settings_all/1` mid-session (see `Valea.Mail.Supervisor`'s
    # moduledoc, "Rehashing") — but that activation is still async in the
    # Engine's own mailbox. Poll `status/1` past `"inactive"` (`nil` too,
    # for the instant right after `reload_settings_all/1` returns but before
    # the child is registered) as the synchronization point.
    defp await_engine_active!(slug) do
      Enum.reduce_while(1..200, nil, fn _, _ ->
        case Engine.status(slug) do
          nil ->
            Process.sleep(5)
            {:cont, nil}

          %{state: "inactive"} ->
            Process.sleep(5)
            {:cont, nil}

          status ->
            {:halt, status}
        end
      end)
    end

    test "reports [] when the workspace is open but no account is configured yet" do
      AgentCase.open_workspace!()
      {:ok, today} = Valea.Cockpit.today()

      # The v4 workspace template ships `accounts: {}` (mail design spec E)
      # — no engine exists for anything, so the list is simply empty.
      assert today["mail"] == []
    end

    test "reports one list entry per configured account, live off Engine.statuses/0" do
      ws = AgentCase.open_workspace!()

      setup_account!(ws.path, "mara")
      await_engine_active!("mara")

      {:ok, today} = Valea.Cockpit.today()

      assert today["mail"] == [
               %{
                 "account" => "mara",
                 "configured" => true,
                 "state" => "idle",
                 "pending_ops" => 0,
                 "notices" => [],
                 "unread" => [],
                 "unread_count" => 0
               }
             ]
    end

    test "multiple accounts sort by slug" do
      ws = AgentCase.open_workspace!()

      setup_account!(ws.path, "priya", "imap.other.com")
      await_engine_active!("priya")
      setup_account!(ws.path, "mara")
      await_engine_active!("mara")

      {:ok, today} = Valea.Cockpit.today()
      assert Enum.map(today["mail"], & &1["account"]) == ["mara", "priya"]
    end

    test "never raises/exits when the Repo is down but an account's Engine is still registered" do
      ws = AgentCase.open_workspace!()
      setup_account!(ws.path, "mara")
      await_engine_active!("mara")

      # The exact window `Valea.Workspace.Manager.do_close/1` opens on every
      # close/switch: `state.children` is `[repo_pid, runtime_pid]`,
      # terminated in list order, so the Repo dies FIRST while an account's
      # Engine (a Runtime->Supervisor grandchild) is still registered.
      # Reproduce it directly by terminating the Repo child;
      # `Valea.Workspace.DynamicSupervisor` never restarts a child it was
      # asked to terminate, so the window stays open for the assertion below.
      repo_pid = Process.whereis(Valea.Repo)
      assert is_pid(repo_pid)
      :ok = DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, repo_pid)

      # `Engine.status/1`'s own `store_snapshot/1` rescue means a dead Repo
      # degrades `pending_ops`/`held_folders`/`backfill` to empty rather than
      # crashing the Engine (and losing its in-RAM credential with it) — so,
      # unlike the old flat `review_count`/`inbox_count` shape (which had
      # nothing sane to report without the DB), the account still shows up
      # with its last-known (DB-independent) `state`. The one hard guarantee
      # this test proves is `mail_summary/0` never raises/exits either way.
      assert Engine.status("mara") != nil
      assert {:ok, %{"mail" => [%{"account" => "mara"}]}} = Valea.Cockpit.today()
    end
  end
end
