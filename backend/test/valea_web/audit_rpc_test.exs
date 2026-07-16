defmodule ValeaWeb.AuditRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

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

    {:ok, ws} = Manager.create("W")

    %{workspace: ws.path}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  defp run_id(suffix), do: "20260710T000000Z-#{suffix}"

  describe "list_audit_entries" do
    test "returns raw heterogeneous entries newest-first, reflecting a prior append" do
      id = run_id("555555")

      # `Valea.Audit` is queue-independent (Spec D §A) — write straight to
      # the audit trail rather than round-tripping through the (deleted)
      # queue approval flow.
      :ok = Valea.Audit.append_sync("item_approved", %{"run_id" => id})

      assert %{"success" => true, "data" => %{"entries" => entries}} =
               rpc("list_audit_entries", %{"limit" => 20}, ["entries"])

      assert is_list(entries)
      assert Enum.any?(entries, &(&1["type"] == "item_approved" and &1["run_id"] == id))
    end

    test "returns an empty list when no workspace-relative entries exist yet" do
      assert %{"success" => true, "data" => %{"entries" => []}} =
               rpc("list_audit_entries", %{"limit" => 20}, ["entries"])
    end
  end
end
