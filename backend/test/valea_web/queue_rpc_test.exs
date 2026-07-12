defmodule ValeaWeb.QueueRpcTest do
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

    parent = Path.join(dir, "workspaces")
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: Path.join(parent, "W"), generation: generation}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  defp run_id(suffix), do: "20260710T000000Z-#{suffix}"

  defp envelope(run_id) do
    %{
      "schema" => "queue_item/v1",
      "run_id" => run_id,
      "session_id" => "sess-1",
      "workflow" => "icm/Workflows/New Inquiry Triage.md",
      "workflow_hash" => String.duplicate("a", 64),
      "input" => "sources/mail/messages/2026-07-09-priya-nair-seed0001.md",
      "input_hash" => String.duplicate("b", 64),
      "risk_level" => "medium",
      "approval" => %{"required" => true},
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "schema" => "proposal/v1",
        "kind" => "email_draft",
        "title" => "Reply to Priya",
        "summary" => "Draft a warm reply to Priya's inquiry",
        "reasoning" => "Priya asked a straightforward pricing question",
        "sources" => ["icm/Clients/Priya Nair.md", "icm/Offers/Starter.md"],
        "proposed_action" => %{
          "type" => "create_email_draft",
          "to" => "priya@example.com",
          "subject" => "Re: Inquiry",
          "body_markdown" => "Hello Priya,\n\nThanks for reaching out!\n"
        }
      }
    }
  end

  defp write_pending(workspace, run_id) do
    envelope = envelope(run_id)
    path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(envelope))
    envelope
  end

  @items_fields [
    %{
      "items" => [
        "runId",
        "title",
        "summary",
        "kind",
        "riskLevel",
        "createdAt",
        "workflow",
        "valid",
        "error"
      ]
    }
  ]

  describe "list_queue_items" do
    test "lists valid and invalid pending entries", %{workspace: workspace} do
      valid_id = run_id("aaaaaa")
      invalid_id = run_id("bbbbbb")
      write_pending(workspace, valid_id)

      invalid_path = Path.join([workspace, "queue", "pending", invalid_id <> ".json"])
      File.mkdir_p!(Path.dirname(invalid_path))
      File.write!(invalid_path, "not json")

      assert %{"success" => true, "data" => %{"items" => items}} =
               rpc("list_queue_items", %{}, @items_fields)

      assert valid = Enum.find(items, &(&1["runId"] == valid_id))
      assert valid["valid"] == true
      assert valid["title"] == "Reply to Priya"
      assert valid["riskLevel"] == "medium"
      assert valid["error"] == nil

      assert invalid = Enum.find(items, &(&1["runId"] == invalid_id))
      assert invalid["valid"] == false
      assert is_binary(invalid["error"])
    end

    test "returns an empty list when the queue is empty" do
      assert %{"success" => true, "data" => %{"items" => []}} =
               rpc("list_queue_items", %{}, @items_fields)
    end
  end

  describe "get_queue_item" do
    test "returns the raw envelope (snake_case, undisturbed) and a revision", %{
      workspace: workspace
    } do
      id = run_id("cccccc")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"item" => item, "revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert item["run_id"] == id
      assert item["schema"] == "queue_item/v1"
      assert item["payload"]["title"] == "Reply to Priya"
      assert is_binary(revision)
      assert byte_size(revision) == 64
    end

    test "a missing run id surfaces queue_item_gone" do
      assert %{"success" => false, "errors" => errors} =
               rpc("get_queue_item", %{"runId" => run_id("dddddd")}, ["item", "revision"])

      assert inspect(errors) =~ "queue_item_gone"
    end
  end

  describe "approve_queue_item" do
    test "happy path writes the draft and returns its path", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("eeeeee")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"item" => _item, "revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => true, "data" => %{"draftPath" => draft_path}} =
               rpc(
                 "approve_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation},
                 ["draftPath"]
               )

      assert draft_path == Path.join(["sources", "mail", "drafts", id <> ".md"])
      assert File.exists?(Path.join(workspace, draft_path))

      approved_path = Path.join([workspace, "queue", "approved", id <> ".json"])
      assert File.exists?(approved_path)
    end

    test "a stale generation surfaces workspace_changed and leaves the item pending", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("ffffff")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "approve_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation - 1},
                 ["draftPath"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.exists?(Path.join([workspace, "queue", "pending", id <> ".json"]))
    end

    test "a stale revision surfaces queue_item_changed", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("111111")
      write_pending(workspace, id)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "approve_queue_item",
                 %{"runId" => id, "revision" => "deadbeef", "generation" => generation},
                 ["draftPath"]
               )

      assert inspect(errors) =~ "queue_item_changed"
    end

    test "an unknown run id surfaces queue_item_gone", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "approve_queue_item",
                 %{
                   "runId" => run_id("222222"),
                   "revision" => "deadbeef",
                   "generation" => generation
                 },
                 ["draftPath"]
               )

      assert inspect(errors) =~ "queue_item_gone"
    end
  end

  describe "reject_queue_item" do
    test "happy path moves the item to rejected and returns rejected: true", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("333333")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => true, "data" => %{"rejected" => true}} =
               rpc(
                 "reject_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation},
                 ["rejected"]
               )

      assert File.exists?(Path.join([workspace, "queue", "rejected", id <> ".json"]))
      refute File.exists?(Path.join([workspace, "queue", "pending", id <> ".json"]))
    end

    test "a stale generation surfaces workspace_changed", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("444444")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "reject_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation - 1},
                 ["rejected"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.exists?(Path.join([workspace, "queue", "pending", id <> ".json"]))
    end

    test "a reason is trimmed and lands in the rejected envelope's decision", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("777777")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => true, "data" => %{"rejected" => true}} =
               rpc(
                 "reject_queue_item",
                 %{
                   "runId" => id,
                   "revision" => revision,
                   "generation" => generation,
                   "reason" => "  not a fit  "
                 },
                 ["rejected"]
               )

      rejected =
        Path.join([workspace, "queue", "rejected", id <> ".json"])
        |> File.read!()
        |> Jason.decode!()

      assert rejected["decision"] == %{"reason" => "not a fit"}
    end

    test "an omitted reason leaves no decision key on the rejected envelope", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("888888")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => true, "data" => %{"rejected" => true}} =
               rpc(
                 "reject_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation},
                 ["rejected"]
               )

      rejected =
        Path.join([workspace, "queue", "rejected", id <> ".json"])
        |> File.read!()
        |> Jason.decode!()

      refute Map.has_key?(rejected, "decision")
    end
  end

  describe "list_decided_items" do
    test "lists a decided (approved) envelope raw, with its mailbox_ops", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("666666")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => true, "data" => %{"draftPath" => _}} =
               rpc(
                 "approve_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation},
                 ["draftPath"]
               )

      assert %{"success" => true, "data" => %{"items" => items}} =
               rpc("list_decided_queue_items", %{}, ["items"])

      assert item = Enum.find(items, &(&1["run_id"] == id))
      assert item["decided"] == "approved"
      assert item["title"] == "Reply to Priya"
      assert Map.has_key?(item, "mailbox_ops")
      assert Map.has_key?(item, "created_at")
    end

    test "returns an empty list when nothing is decided yet" do
      assert %{"success" => true, "data" => %{"items" => []}} =
               rpc("list_decided_queue_items", %{}, ["items"])
    end
  end

  describe "list_audit_entries" do
    test "returns raw heterogeneous entries newest-first, reflecting a prior approval", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("555555")
      write_pending(workspace, id)

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      rpc(
        "approve_queue_item",
        %{"runId" => id, "revision" => revision, "generation" => generation},
        ["draftPath"]
      )

      assert %{"success" => true, "data" => %{"entries" => entries}} =
               rpc("list_audit_entries", %{"limit" => 20}, ["entries"])

      assert is_list(entries)
      assert Enum.any?(entries, &(&1["type"] == "item_approved" and &1["run_id"] == id))
    end
  end
end
