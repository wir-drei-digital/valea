defmodule Valea.Api.SchedulesTest do
  @moduledoc """
  Direct Ash-action coverage for `Valea.Api.Schedules` (the `Valea.Api.Skills`
  style — actions through `Ash.ActionInput.for_action/3`, no RPC transport).
  The scheduler's own firing semantics live in `Valea.Schedules.SchedulerTest`;
  this suite pins the RPC surface: dispositions and `next_fire` on the list,
  ledger edits through `Valea.Schedules.Edit`, the run-history projection (the
  `waiting` join is READ-ONLY — nothing ever persists that outcome), the
  tri-state kill switch, the generation guard, and the audit entries.
  """
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Api.Schedules, as: ApiSchedules
  alias Valea.Mounts
  alias Valea.Schedules.Store
  alias Valea.Workspace.Manager

  setup do
    ws = AgentCase.open_workspace!("W")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{ws: ws.path, icm: icm, key: icm.mount_key, generation: Manager.generation()}
  end

  defp run(action, input) do
    ApiSchedules
    |> Ash.ActionInput.for_action(action, input)
    |> Ash.run_action()
  end

  defp write_schedules!(icm, schedules) do
    File.write!(
      Path.join(icm.root, "schedules.json"),
      Jason.encode!(%{"readme" => "keep me", "schedules" => schedules})
    )
  end

  defp read_schedules(icm) do
    icm.root |> Path.join("schedules.json") |> File.read!() |> Jason.decode!()
  end

  defp prompt_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "s-brief",
        "title" => "Morning brief",
        "cron" => "30 7 * * 1-5",
        "timezone" => "Europe/Zurich",
        "payload" => %{"kind" => "prompt", "prompt" => "Work the inbox."}
      },
      overrides
    )
  end

  defp audit_entry(type) do
    {:ok, entries} = Valea.Audit.entries(50)
    Enum.find(entries, &(&1["type"] == type))
  end

  defp schedule_row(payload, id) do
    [%{"schedules" => rows}] = payload["icms"]
    Enum.find(rows, &(&1["id"] == id))
  end

  describe "list_schedules" do
    test "an executable entry carries its cadence, payload kind and a next_fire", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry()])

      assert {:ok, payload} = run(:list_schedules, %{generation: generation})
      assert [%{"mount_key" => ^key, "icm_name" => "Primary", "status" => "ok"}] = payload["icms"]

      row = schedule_row(payload, "s-brief")
      assert row["title"] == "Morning brief"
      assert row["disposition"] == "executable"
      assert row["reason"] == nil
      assert row["cadence"] == "30 7 * * 1-5"
      assert row["timezone"] == "Europe/Zurich"
      assert row["payload_kind"] == "prompt"
      assert row["paused"] == false
      assert row["last_outcome"] == nil
      assert {:ok, _fire, _offset} = DateTime.from_iso8601(row["next_fire"])
    end

    test "the workspace kill switch rides the list as a tri-state string", %{
      icm: icm,
      ws: ws,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry()])

      assert {:ok, %{"scheduler_paused" => "off"}} =
               run(:list_schedules, %{generation: generation})

      :ok = Mounts.set_scheduler_paused(ws, true)

      assert {:ok, %{"scheduler_paused" => "on"}} =
               run(:list_schedules, %{generation: generation})

      File.write!(Path.join(ws, "config/workspace.yaml"), ": : not yaml : :")

      assert {:ok, %{"scheduler_paused" => "unreadable"}} =
               run(:list_schedules, %{generation: generation})
    end

    test "a paused entry is disposition paused; an invalid one carries its reason", %{
      icm: icm,
      generation: generation
    } do
      write_schedules!(icm, [
        prompt_entry(%{"id" => "s-paused", "paused" => true}),
        prompt_entry(%{"id" => "s-bad", "cron" => "not a cron"}),
        prompt_entry(%{"id" => "s-strpause", "paused" => "true"})
      ])

      assert {:ok, payload} = run(:list_schedules, %{generation: generation})

      paused = schedule_row(payload, "s-paused")
      assert paused["disposition"] == "paused"
      assert paused["paused"] == true
      # A paused entry never fires on cadence, so it advertises no next fire.
      assert paused["next_fire"] == nil

      bad = schedule_row(payload, "s-bad")
      assert bad["disposition"] == "not_executable"
      assert bad["reason"] =~ "invalid cron"
      assert bad["next_fire"] == nil
      # Lenient display: the payload chip survives an entry refused for its cron.
      assert bad["payload_kind"] == "prompt"

      # The case the strict regime exists for: a STRING "true" pause.
      strpause = schedule_row(payload, "s-strpause")
      assert strpause["disposition"] == "not_executable"
      assert strpause["reason"] =~ "boolean"
    end

    test "duplicate ids make every carrier not_executable", %{icm: icm, generation: generation} do
      write_schedules!(icm, [prompt_entry(), prompt_entry(%{"title" => "Second"})])

      assert {:ok, payload} = run(:list_schedules, %{generation: generation})
      [%{"schedules" => rows}] = payload["icms"]

      assert Enum.map(rows, & &1["disposition"]) == ["not_executable", "not_executable"]
      assert Enum.all?(rows, &(&1["reason"] == "duplicate id"))
    end

    test "an unreadable ledger degrades to status unreadable with no entries", %{
      icm: icm,
      generation: generation
    } do
      File.write!(Path.join(icm.root, "schedules.json"), "{not json")

      assert {:ok, %{"icms" => [%{"status" => "unreadable", "schedules" => []}]}} =
               run(:list_schedules, %{generation: generation})
    end

    test "last_outcome comes off the newest run row and registered_recently off first_seen_at",
         %{icm: icm, generation: generation} do
      write_schedules!(icm, [prompt_entry()])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _older} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-brief",
          fingerprint: "fp",
          slot: DateTime.add(now, -7200, :second),
          fired_at: DateTime.add(now, -7200, :second),
          trigger: "scheduled",
          kind: "prompt",
          outcome: "completed",
          mount_key: icm.mount_key
        })

      {:ok, _newest} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-brief",
          fingerprint: "fp",
          slot: DateTime.add(now, -60, :second),
          fired_at: DateTime.add(now, -60, :second),
          trigger: "scheduled",
          kind: "prompt",
          outcome: "failed",
          mount_key: icm.mount_key
        })

      :ok = Store.put_state(icm.id, "s-brief", %{fingerprint: "fp", first_seen_at: now})

      assert {:ok, payload} = run(:list_schedules, %{generation: generation})
      row = schedule_row(payload, "s-brief")
      assert row["last_outcome"] == "failed"
      assert row["registered_recently"] == true
    end
  end

  describe "create_schedule / mutate_schedule / delete_schedule" do
    test "create lands in the file with a generated id and audits schedule_edited", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      assert {:ok, %{"schedule" => schedule}} =
               run(:create_schedule, %{
                 mount_key: key,
                 fields: %{
                   "title" => "Nightly sync",
                   "cron" => "@daily",
                   "payload" => %{"kind" => "command", "command" => "true"}
                 },
                 generation: generation
               })

      assert schedule["id"] =~ ~r/^s-[0-9a-f]{6}$/
      assert schedule["created_by"] == "user"
      assert %{"schedules" => [written]} = read_schedules(icm)
      assert written["id"] == schedule["id"]

      assert entry = audit_entry("schedule_edited")
      assert entry["mount_key"] == key
      assert entry["schedule_id"] == schedule["id"]
      assert entry["action"] == "create"
    end

    test "mutate patches by TRIMMED id and preserves unknown fields", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry(%{"id" => " s-brief ", "mystery" => %{"a" => 1}})])

      assert {:ok, %{"schedule" => schedule}} =
               run(:mutate_schedule, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 patch: %{"paused" => true},
                 generation: generation
               })

      assert schedule["paused"] == true
      assert schedule["mystery"] == %{"a" => 1}
      assert read_schedules(icm)["readme"] == "keep me"
      assert audit_entry("schedule_edited")["action"] == "mutate"
    end

    test "delete removes exactly that entry and audits", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry(), prompt_entry(%{"id" => "s-other"})])

      assert {:ok, %{"deleted" => true}} =
               run(:delete_schedule, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 generation: generation
               })

      assert %{"schedules" => [only]} = read_schedules(icm)
      assert only["id"] == "s-other"
      assert audit_entry("schedule_edited")["action"] == "delete"
    end

    test "mutate/delete on an unknown id is not_found and writes nothing", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry()])
      before = read_schedules(icm)

      for {action, input} <- [
            {:mutate_schedule,
             %{
               mount_key: key,
               schedule_id: "s-nope",
               patch: %{"paused" => true},
               generation: generation
             }},
            {:delete_schedule, %{mount_key: key, schedule_id: "s-nope", generation: generation}}
          ] do
        assert {:error, error} = run(action, input)
        assert %Valea.Api.Error{code: "not_found"} = error.errors |> hd()
      end

      assert read_schedules(icm) == before
    end

    test "a duplicate id refuses the mutation — order never decides", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry(), prompt_entry(%{"title" => "Second"})])
      before = read_schedules(icm)

      assert {:error, error} =
               run(:mutate_schedule, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 patch: %{"paused" => true},
                 generation: generation
               })

      assert %Valea.Api.Error{code: "duplicate_id"} = error.errors |> hd()
      assert read_schedules(icm) == before
    end

    test "an unreadable ledger refuses every edit", %{icm: icm, key: key, generation: generation} do
      File.write!(Path.join(icm.root, "schedules.json"), "{not json")

      assert {:error, error} =
               run(:create_schedule, %{
                 mount_key: key,
                 fields: %{"title" => "x", "cron" => "@daily"},
                 generation: generation
               })

      assert %Valea.Api.Error{code: "unreadable"} = error.errors |> hd()
    end
  end

  describe "run_schedule_now" do
    test "a not_executable entry is refused", %{icm: icm, key: key, generation: generation} do
      write_schedules!(icm, [prompt_entry(%{"cron" => "not a cron"})])

      assert {:error, error} =
               run(:run_schedule_now, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 generation: generation
               })

      assert %Valea.Api.Error{code: "not_executable"} = error.errors |> hd()
    end

    test "an unknown id is not_found", %{icm: icm, key: key, generation: generation} do
      write_schedules!(icm, [prompt_entry()])

      assert {:error, error} =
               run(:run_schedule_now, %{
                 mount_key: key,
                 schedule_id: "s-ghost",
                 generation: generation
               })

      assert %Valea.Api.Error{code: "not_found"} = error.errors |> hd()
    end

    test "the kill switch refuses a manual run", %{
      ws: ws,
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry()])
      :ok = Mounts.set_scheduler_paused(ws, true)

      assert {:error, error} =
               run(:run_schedule_now, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 generation: generation
               })

      assert %Valea.Api.Error{code: "scheduler_paused"} = error.errors |> hd()
    end
  end

  describe "schedule_run_history" do
    test "returns the run rows newest-first with output and session_id", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_schedules!(icm, [prompt_entry()])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _older} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-brief",
          fingerprint: "fp",
          slot: DateTime.add(now, -7200, :second),
          fired_at: DateTime.add(now, -7200, :second),
          trigger: "scheduled",
          kind: "command",
          outcome: "completed",
          duration_ms: 42,
          output: "hello from the command",
          coalesced_count: 2,
          mount_key: icm.mount_key
        })

      {:ok, _newest} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-brief",
          fingerprint: "fp",
          slot: now,
          fired_at: now,
          trigger: "manual",
          kind: "prompt",
          outcome: "running",
          session_id: "sess-gone",
          mount_key: icm.mount_key
        })

      assert {:ok, %{"runs" => [newest, older]}} =
               run(:schedule_run_history, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 generation: generation
               })

      assert newest["trigger"] == "manual"
      assert newest["session_id"] == "sess-gone"
      # No live session, so nothing to project: the stored outcome stands.
      assert newest["outcome"] == "running"

      assert older["outcome"] == "completed"
      assert older["duration_ms"] == 42
      assert older["output"] == "hello from the command"
      assert older["coalesced_count"] == 2
      assert is_binary(older["fired_at"])
      assert is_binary(older["slot"])
    end

    # Constraint the earlier review rounds pinned: `waiting` exists ONLY as a
    # read-time projection. Persisting it would hide the row from
    # `Store.running_runs/1` (literal `"running"` match) — the query that
    # enforces one-run-at-a-time AND converges abandoned rows — and would
    # freeze a permanent cockpit notice for a run that has since been approved.
    test "a prompt run whose session is parked on an ask projects waiting, and the store still says running",
         %{ws: ws, icm: icm, key: key, generation: generation} do
      write_schedules!(icm, [prompt_entry()])

      {:ok, %{id: session_id}} =
        Valea.AgentCase.start_session(ws, "permission", %{mount_key: key, kind: "scheduled"})

      on_exit(fn -> Valea.AgentCase.kill_session(session_id) end)

      Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> session_id)
      :ok = Valea.Agents.SessionServer.prompt(session_id, "write")
      assert_receive {:session_event, _seq, %{"type" => "permission"} = ask}, 10_000

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _run} =
        Store.record_run(%{
          icm_id: icm.id,
          schedule_id: "s-brief",
          fingerprint: "fp",
          slot: now,
          fired_at: now,
          trigger: "scheduled",
          kind: "prompt",
          outcome: "running",
          session_id: session_id,
          mount_key: icm.mount_key
        })

      assert {:ok, %{"runs" => [run]}} =
               run(:schedule_run_history, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 generation: generation
               })

      assert run["outcome"] == "waiting"
      assert run["session_id"] == session_id
      assert [%{outcome: "running"}] = Store.running_runs(icm_id: icm.id)

      # The row is also a cockpit notice while it is parked...
      {:ok, %{"schedule_notices" => notices}} = Valea.Cockpit.today()
      assert Enum.find(notices, &(&1["kind"] == "waiting"))["schedule_id"] == "s-brief"

      # ...and stops being one the moment the human answers, with nothing
      # written to the store in either direction.
      :ok = Valea.Agents.SessionServer.answer_permission(session_id, ask["id"], "allow_once")
      assert_receive {:session_event, _seq, %{"type" => "turn"}}, 10_000

      assert {:ok, %{"runs" => [reprojected]}} =
               run(:schedule_run_history, %{
                 mount_key: key,
                 schedule_id: "s-brief",
                 generation: generation
               })

      assert reprojected["outcome"] == "running"
      {:ok, %{"schedule_notices" => after_answer}} = Valea.Cockpit.today()
      assert Enum.find(after_answer, &(&1["kind"] == "waiting")) == nil
    end

    test "history survives a deleted schedule and honors limit", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..3 do
        {:ok, _run} =
          Store.record_run(%{
            icm_id: icm.id,
            schedule_id: "s-gone",
            fingerprint: "fp",
            slot: DateTime.add(now, -i * 60, :second),
            fired_at: DateTime.add(now, -i * 60, :second),
            trigger: "scheduled",
            kind: "command",
            outcome: "completed",
            mount_key: icm.mount_key
          })
      end

      assert {:ok, %{"runs" => runs}} =
               run(:schedule_run_history, %{
                 mount_key: key,
                 schedule_id: "s-gone",
                 limit: 2,
                 generation: generation
               })

      assert length(runs) == 2
    end
  end

  describe "set_scheduler_paused" do
    test "round-trips workspace.yaml, audits, and reports the tri-state", %{
      ws: ws,
      generation: generation
    } do
      assert {:ok, %{"scheduler_paused" => "on"}} =
               run(:set_scheduler_paused, %{paused: true, generation: generation})

      assert Mounts.scheduler_pause_state(ws) == :on
      assert audit_entry("scheduler_pause_set")["scheduler_paused"] == "on"

      assert {:ok, %{"scheduler_paused" => "off"}} =
               run(:set_scheduler_paused, %{paused: false, generation: generation})

      assert Mounts.scheduler_pause_state(ws) == :off
      # Every other key in the config survives the toggle.
      assert Mounts.list(ws) != []
    end
  end

  test "every action rejects a stale generation with workspace_changed", %{
    key: key,
    generation: generation
  } do
    stale = generation + 1

    for {action, input} <- [
          {:list_schedules, %{generation: stale}},
          {:create_schedule,
           %{mount_key: key, fields: %{"title" => "x", "cron" => "@daily"}, generation: stale}},
          {:mutate_schedule,
           %{
             mount_key: key,
             schedule_id: "s-brief",
             patch: %{"paused" => true},
             generation: stale
           }},
          {:delete_schedule, %{mount_key: key, schedule_id: "s-brief", generation: stale}},
          {:run_schedule_now, %{mount_key: key, schedule_id: "s-brief", generation: stale}},
          {:schedule_run_history, %{mount_key: key, schedule_id: "s-brief", generation: stale}},
          {:set_scheduler_paused, %{paused: true, generation: stale}}
        ] do
      assert {:error, error} = run(action, input),
             "expected stale-generation refusal for #{action}"

      assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()
    end
  end

  test "a ledger edit with the writer gone is workspace_not_open, not a crash", %{
    key: key,
    generation: generation
  } do
    :ok = Supervisor.terminate_child(Valea.Schedules.Supervisor, Valea.Ledger.Writer)
    on_exit(fn -> Supervisor.restart_child(Valea.Schedules.Supervisor, Valea.Ledger.Writer) end)

    assert {:error, error} =
             run(:create_schedule, %{
               mount_key: key,
               fields: %{"title" => "x", "cron" => "@daily"},
               generation: generation
             })

    assert %Valea.Api.Error{code: "workspace_not_open"} = error.errors |> hd()
  end
end
