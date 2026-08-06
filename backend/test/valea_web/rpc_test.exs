defmodule ValeaWeb.RpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  test "get_workspace reports closed, then open after create_workspace" do
    assert %{"success" => true, "data" => %{"open" => false}} = rpc("get_workspace", %{})

    assert %{"success" => true, "data" => %{"open" => true, "name" => "W", "id" => id} = data} =
             rpc("create_workspace", %{"name" => "W"})

    assert is_binary(id)
    refute Map.has_key?(data, "path")

    assert %{"success" => true, "data" => %{"open" => true}} = rpc("get_workspace", %{})
  end

  test "icm_tree requires a workspace" do
    # `:tree` is a `constraints fields: [...]` typed action taking
    # `mountKey` + `generation` (task 4.2's re-key — one ICM's tree,
    # generation-guarded the same way `Valea.Api.Icms.list_icms` is: see
    # `Valea.Api.ICM`'s moduledoc). With no workspace open,
    # `Manager.check_generation/1` itself is what rejects the call (a
    # closed workspace never matches any generation), so this surfaces
    # `workspace_changed`, not `workspace_not_open` — `Valea.ICM.tree_for/1`'s
    # own `:no_workspace` check never even runs.
    assert %{"success" => false, "errors" => errors} =
             rpc(
               "icm_tree",
               %{"mountKey" => "primary", "generation" => 0},
               ["mountKey", "title", "tree"]
             )

    assert inspect(errors) =~ "workspace_changed"
  end

  test "icm_tree and cockpit_today succeed with a workspace open" do
    # `Valea.Mounts.list/1` is config truth over `icms:` only — a fresh v5
    # workspace seeds no mount at all — so the ICM content this test
    # exercises comes from a REAL EXTERNAL ICM mounted via
    # `AgentCase.mount_test_icm!/2`.
    {:ok, ws} = Manager.create("Primary")

    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary", pages: %{"Offers/X.md" => "# X\n"})

    assert %{"success" => true, "data" => %{"generation" => generation}} =
             rpc("get_workspace", %{})

    assert %{"success" => true, "data" => mount} =
             rpc(
               "icm_tree",
               %{"mountKey" => icm.mount_key, "generation" => generation},
               ["mountKey", "title", "tree"]
             )

    assert mount["mountKey"] == icm.mount_key
    assert Enum.any?(mount["tree"], &(&1["name"] == "Offers"))

    assert %{
             "success" => true,
             "data" => %{"sections" => sections, "mail" => mail}
           } = rpc("cockpit_today", %{}, ["sections", "mail"])

    # No `today.json` was ever written into the mounted ICM above, and it STILL
    # gets a section (Today/Tasks redesign 2026-08-06): `todayJson` reports the
    # briefing file's state rather than the section's existence hinging on it —
    # this RPC round trip just confirms the typed `:today` action shape holds
    # together end-to-end, not the section-assembly logic itself (that's
    # `test/valea/cockpit_test.exs`'s job).
    assert [section] = sections
    assert section["mountKey"] == icm.mount_key
    assert section["todayJson"] == "absent"

    # A freshly created workspace has no mail account configured yet — the
    # v4 workspace template ships `accounts: {}` (mail design spec E), so
    # `Valea.Mail.Supervisor` starts no engine at all and the list is empty.
    assert mail == []
  end

  # Mirrors `write_session_meta!/3` in `test/valea/cockpit_test.exs` (added in
  # c0cb967) — a bare transcript line-1 metadata file, no live `SessionServer`
  # behind it, so `Valea.Agents.list_sessions/0`'s `live_status/1` resolves it
  # to `{false, "ended"}`.
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

  # Review finding (Task 3): `recent_sessions[].live == false` was only ever
  # exercised by calling `Valea.Cockpit.today/0` directly — never through the
  # full RPC path, which is the one layer where `Ash.Type.Map`'s
  # `check_fields/2`/`fetch_field/2` constraint casting could null a legitimate
  # `false` if the source map weren't string-keyed (the ash_typescript 0.17.3
  # falsy-bool issue documented in `Valea.Api.Cockpit`'s moduledoc and
  # `Valea.Api.Queue.reject_item`/`Valea.Api.Mail`'s). An ended (non-live)
  # session transcript drives that leaf (→ `recentSessions[0]["live"]`) here;
  # the section's own falsy bool is GONE with `ok` (Today/Tasks redesign — the
  # `todayJson` state string replaced it), so this round trip also pins the
  # replacement's `"unreadable"` reaching the wire under its camelCased name.
  # `sections[].tasks.top[].today == false` (the remaining nested-in-a-nested-
  # map falsy leaf) is pinned by the tasks-line RPC test below.
  test "cockpit_today RPC: a malformed today.json reads unreadable, an ended session keeps its `false`" do
    {:ok, ws} = Manager.create("Falsy")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Broken")
    File.write!(Path.join(icm.root, "today.json"), "{not json")
    write_session_meta!(ws.path, "session-ended-1", "2026-01-01T00:00:01Z")

    assert %{
             "success" => true,
             "data" => %{"sections" => [section], "recentSessions" => [session]}
           } = rpc("cockpit_today", %{}, ["sections", "recentSessions"])

    assert section["todayJson"] == "unreadable"

    # The `false` itself, not merely "falsy" — this is what the reviewer
    # feared could get nulled by `check_fields/2` on a non-string-keyed
    # source map.
    assert session["live"] == false
    assert is_boolean(session["live"])
    assert session["status"] == "ended"
  end

  # The one layer the direct-Ash suites (`Valea.Api.TasksTest`,
  # `Valea.Api.SchedulesTest`) cannot see: ash_typescript's own field
  # extraction. Three things can only break HERE —
  #
  #   1. a typed row's snake_case source key resolving under its camelCase
  #      declaration (`mount_key` -> `mountKey`);
  #   2. an UNCONSTRAINED array passing its items through verbatim, so the
  #      user's own file fields (and their legitimately-`false` values) reach
  #      the frontend unrenamed and unnulled;
  #   3. an unconstrained `:map` ARGUMENT surviving in the other direction —
  #      the composer sends `tasks.json`'s own snake_case field names, and
  #      nothing on the way in may camelCase them.
  test "tasks + schedules RPC: typed rows camelCase, file entries pass through verbatim" do
    {:ok, ws} = Manager.create("Wire")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")

    File.write!(
      Path.join(icm.root, "schedules.json"),
      Jason.encode!(%{
        "schedules" => [
          %{
            "id" => "s-brief",
            "title" => "Morning brief",
            "cron" => "30 7 * * 1-5",
            "paused" => false,
            "payload" => %{"kind" => "prompt", "prompt" => "go"},
            "mystery" => %{"kept" => true}
          }
        ]
      })
    )

    assert %{"success" => true, "data" => %{"generation" => generation}} =
             rpc("get_workspace", %{})

    # (3) `fields` goes over the wire with the FILE's key names.
    assert %{"success" => true, "data" => %{"task" => created}} =
             rpc(
               "create_task",
               %{
                 "mountKey" => icm.mount_key,
                 "generation" => generation,
                 "fields" => %{"title" => "Wire task", "today" => false, "priority" => "high"}
               },
               ["task"]
             )

    assert created["title"] == "Wire task"
    assert created["priority"] == "high"

    assert %{"success" => true, "data" => %{"icms" => [tasks_row]}} =
             rpc("list_tasks", %{"generation" => generation}, [
               %{"icms" => ["mountKey", "icmName", "status", "tasks"]}
             ])

    # (1) typed keys camelCased...
    assert tasks_row["mountKey"] == icm.mount_key
    assert tasks_row["status"] == "ok"

    # ...(2) and the entry itself verbatim, `false` intact.
    assert [task] = tasks_row["tasks"]
    assert task["title"] == "Wire task"
    assert task["today"] == false
    assert is_boolean(task["today"])
    assert task["created_by"] == "user"

    assert %{
             "success" => true,
             "data" => %{"icms" => [schedules_row], "schedulerPaused" => "off"}
           } =
             rpc("list_schedules", %{"generation" => generation}, [
               %{"icms" => ["mountKey", "icmName", "status", "schedules"]},
               "schedulerPaused"
             ])

    assert [schedule] = schedules_row["schedules"]
    assert schedule["id"] == "s-brief"
    assert schedule["disposition"] == "executable"
    assert schedule["paused"] == false
    assert is_boolean(schedule["paused"])
    assert is_binary(schedule["next_fire"])

    assert %{"success" => true, "data" => %{"runs" => []}} =
             rpc(
               "schedule_run_history",
               %{
                 "mountKey" => icm.mount_key,
                 "scheduleId" => "s-brief",
                 "generation" => generation
               },
               ["runs"]
             )
  end

  test "cockpit_today RPC: the tasks line survives extraction, malformed ledger nulls it" do
    {:ok, ws} = Manager.create("Cockpit")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    File.write!(Path.join(icm.root, "today.json"), ~s({"notes": "n"}))

    File.write!(
      Path.join(icm.root, "tasks.json"),
      Jason.encode!(%{
        "tasks" => [%{"id" => "t-1", "title" => "Ship", "status" => "in_progress"}]
      })
    )

    fields = [
      %{
        "sections" => [
          "mountKey",
          "todayJson",
          %{"tasks" => ["dueToday", "overdue", "inProgress", %{"top" => ["id", "today"]}]}
        ]
      },
      %{"scheduleNotices" => ["kind", "scheduleId", "title", "at"]}
    ]

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _run} =
      Valea.Schedules.Store.record_run(%{
        icm_id: icm.id,
        schedule_id: "s-gone",
        fingerprint: "fp",
        slot: now,
        fired_at: now,
        trigger: "scheduled",
        kind: "command",
        outcome: "failed",
        output: "SECRET OUTPUT",
        mount_key: icm.mount_key
      })

    assert %{
             "success" => true,
             "data" => %{"sections" => [section], "scheduleNotices" => [notice]}
           } =
             rpc("cockpit_today", %{}, fields)

    # A NESTED `:map` field (`tasks`, like the pre-existing `calendar` line)
    # passes its inner keys through VERBATIM — ash_typescript camelCases the
    # declared names in the emitted TS types, but the runtime extraction only
    # renames fields of ARRAY items (`sections[]`, `scheduleNotices[]` below).
    # `lib/today/cockpit.ts` already normalizes both spellings for exactly this
    # reason; the assertion pins the wire truth rather than the type's promise.
    assert section["tasks"]["in_progress"] == 1
    assert section["tasks"]["due_today"] == 0
    # The `today` flag is the falsy leaf inside the nested top items.
    assert [%{"id" => "t-1", "today" => false}] = section["tasks"]["top"]

    # Array items DO get camelCased — and a notice carries no output, ever.
    assert notice["kind"] == "failed"
    assert notice["scheduleId"] == "s-gone"
    assert is_binary(notice["at"])
    refute Jason.encode!(notice) =~ "SECRET OUTPUT"

    File.write!(Path.join(icm.root, "tasks.json"), "{not json")

    assert %{"success" => true, "data" => %{"sections" => [degraded]}} =
             rpc("cockpit_today", %{}, fields)

    assert degraded["todayJson"] == "present"
    assert degraded["tasks"] == nil
  end
end
