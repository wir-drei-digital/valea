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
                 "notices" => []
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
