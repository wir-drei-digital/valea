defmodule ValeaWeb.RpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mail.Engine
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  # The workspace template still scaffolds the legacy `icm/` tree (Task
  # A-T8 migrates it) — a fresh scaffold has no `mounts/` dir at all, so
  # `Valea.ICM.tree/0` (and the `icm_tree` RPC action wrapping it) returns
  # no entries until a mount exists. Copy the seeded `icm/` tree into
  # `mounts/primary/` and stamp a manifest on it, mirroring the same fixture
  # pattern used in `test/valea_web/icm_rpc_test.exs`.
  defp seed_mount!(ws_path, name, title) do
    mount_dir = Path.join([ws_path, "mounts", name])
    File.mkdir_p!(Path.dirname(mount_dir))
    File.cp_r!(Path.join(ws_path, "icm"), mount_dir)
    Manifest.write!(mount_dir, %{id: "id-" <> name, name: title, description: ""})
  end

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

    %{parent: Path.join(dir, "workspaces")}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  test "get_workspace reports closed, then open after create_workspace", %{parent: parent} do
    assert %{"success" => true, "data" => %{"open" => false}} = rpc("get_workspace", %{})

    assert %{"success" => true, "data" => %{"open" => true, "name" => "W"}} =
             rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})

    assert %{"success" => true, "data" => %{"open" => true}} = rpc("get_workspace", %{})
  end

  test "icm_tree requires a workspace" do
    assert %{"success" => false, "errors" => errors} = rpc("icm_tree", %{})
    assert inspect(errors) =~ "workspace_not_open"
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

  test "icm_tree and cockpit_today succeed with a workspace open", %{parent: parent} do
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})
    await_engine_active!()
    seed_mount!(Path.join(parent, "W"), "primary", "Primary")

    assert %{"success" => true, "data" => %{"nodes" => [mount]}} = rpc("icm_tree", %{})
    assert mount["mount"] == "primary"
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
