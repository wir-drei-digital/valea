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
             "data" => %{"greeting" => "Good morning, Mara.", "mail" => mail}
           } = rpc("cockpit_today", %{}, ["greeting", "mail"])

    # A freshly created workspace has no mail account configured yet, but
    # its `Valea.Mail.Engine` IS running (`Valea.Workspace.Runtime` starts
    # it inert) — the unconfigured default comes from the Engine itself
    # here, not from the `Process.whereis/1` guard (see
    # `Valea.Cockpit.today/0`'s moduledoc), which `icm_tree requires a
    # workspace` above already exercises with no workspace at all.
    # `reviewCount` is 1 — the workspace template seeds ONE `status: review`
    # message (`sources/mail/messages/2026-07-09-priya-nair-seed0001.md`,
    # indexed into `Valea.Mail.Store` on workspace open) so Task 18's
    # generalized Today card has something to show before any real mail
    # ever syncs.
    assert mail == %{"reviewCount" => 1, "inboxCount" => 0, "configured" => false}
  end
end
