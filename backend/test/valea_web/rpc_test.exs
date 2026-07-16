defmodule ValeaWeb.RpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Mail.Engine
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

  # `create_workspace` returns as soon as `Manager.create/2` does — it does
  # NOT wait for `Valea.Mail.Engine` to finish reacting to the
  # `:workspace_opened` broadcast (its own mailbox, a separate process from
  # this request). Activation is where `Index.rebuild/1` actually runs, so
  # the very next request can race an engine that's still "inactive"; see
  # the identical helper/comment in `test/valea/cockpit_test.exs`.
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

  test "icm_tree and cockpit_today succeed with a workspace open" do
    # `Valea.Mounts.list/1` is config truth over `icms:` only — a fresh v5
    # workspace seeds no mount at all — so the ICM content this test
    # exercises comes from a REAL EXTERNAL ICM mounted via
    # `AgentCase.mount_test_icm!/2`.
    {:ok, ws} = Manager.create("Primary")
    await_engine_active!()

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

    # No `today.json` was ever written into the mounted ICM above, so it
    # contributes no section (Spec D §C leniency contract: absent file →
    # no section) — this RPC round trip just confirms the typed `:today`
    # action shape holds together end-to-end, not the section-assembly
    # logic itself (that's `test/valea/cockpit_test.exs`'s job).
    assert sections == []

    # A freshly created workspace has no mail account configured yet, but
    # its `Valea.Mail.Engine` IS running (`Valea.Workspace.Runtime` starts
    # it inert) — the unconfigured default comes from the Engine itself
    # here, not from the `Process.whereis/1` guard (see
    # `Valea.Cockpit.today/0`'s moduledoc), which `icm_tree requires a
    # workspace` above already exercises with no workspace at all.
    # `reviewCount` is 1 — the workspace template seeds ONE `status: review`
    # message (`sources/mail/messages/2026-07-09-priya-nair-seed0001.md`,
    # indexed into `Valea.Mail.Store` on workspace open) so Today's mail
    # summary has something to show before any real mail ever syncs.
    assert mail == %{"reviewCount" => 1, "inboxCount" => 0, "configured" => false}
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

  # Review finding (Task 3): `sections[].ok == false` and
  # `recent_sessions[].live == false` were only ever exercised by calling
  # `Valea.Cockpit.today/0` directly — never through the full RPC path, which
  # is the one layer where `Ash.Type.Map`'s `check_fields/2`/`fetch_field/2`
  # constraint casting could null a legitimate `false` if the source map
  # weren't string-keyed (the ash_typescript 0.17.3 falsy-bool issue
  # documented in `Valea.Api.Cockpit`'s moduledoc and
  # `Valea.Api.Queue.reject_item`/`Valea.Api.Mail`'s). This drives BOTH
  # falsy-bool leaves through `POST /rpc/run` in one round trip: a malformed
  # `today.json` (→ `sections[0]["ok"]`) and an ended (non-live) session
  # transcript (→ `recentSessions[0]["live"]`) — proving `false` survives
  # extraction as `false`, not `nil`/missing.
  test "cockpit_today RPC: malformed today.json and an ended session both keep their `false`" do
    {:ok, ws} = Manager.create("Falsy")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Broken")
    File.write!(Path.join(icm.root, "today.json"), "{not json")
    write_session_meta!(ws.path, "session-ended-1", "2026-01-01T00:00:01Z")

    assert %{
             "success" => true,
             "data" => %{"sections" => [section], "recentSessions" => [session]}
           } = rpc("cockpit_today", %{}, ["sections", "recentSessions"])

    # The `false` itself, not merely "falsy" — this is what the reviewer
    # feared could get nulled by `check_fields/2` on a non-string-keyed
    # source map.
    assert section["ok"] == false
    assert is_boolean(section["ok"])

    assert session["live"] == false
    assert is_boolean(session["live"])
    assert session["status"] == "ended"
  end
end
