defmodule ValeaWeb.QueueRpcTest do
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

    # Legacy path-based `Manager.create/2` (v4, starter mount) — called
    # directly rather than through the `create_workspace` RPC, which is now
    # the C9 id-based surface (`Manager.create/1`, v5, no `mounts/`). This
    # suite exercises `mounts/w/...` starter-mount content the id-based
    # create can't provide yet (Phase 3 introduces the config-backed ICM
    # registry) — see `Valea.Api.Workspace`'s moduledoc.
    parent = Path.join(dir, "workspaces")
    {:ok, _} = Manager.create(parent, "W")
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

  # Inlined/adapted from `Valea.QueueTest`'s `pending_memory!/5` (B4) — same
  # minimal `queue_item/v2` + `memory_update` envelope shape, just written
  # via this test's own `write_pending`-style raw-file helper instead of
  # `AgentCase.open_workspace!/1`. `"workflow"` is a bare informational
  # string here (never attributed to a real mount by `approve_queue_item`,
  # mirrors `Valea.QueueTest`'s own `pending_memory!/5`, which leaves it as
  # an untouched literal too) — only `target_path` (the actual
  # `apply_page_content` target) needs to attribute to a real, mounted ICM,
  # via `Mounts.mount_for/2`.
  defp write_pending_memory(workspace, run_id, target, base, content) do
    item = %{
      "schema" => "queue_item/v2",
      "run_id" => run_id,
      "workflow" => "mounts/w/Workflows/New Inquiry Triage.md",
      "risk_level" => "medium",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "title" => "Update x",
        "summary" => "why",
        "kind" => "memory_update",
        "sources" => [],
        "proposed_action" => %{
          "type" => "apply_page_content",
          "target_path" => target,
          "base_sha256" => base,
          "content_markdown" => content
        }
      }
    }

    path = Path.join([workspace, "queue", "pending", run_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(item))
    item
  end

  # Mounts a real EXTERNAL ICM carrying a `Pricing/Current Pricing.md` seed
  # page — the target the `approve_queue_item` memory-update tests below
  # read/write. Post-task-3.2, `Valea.Mounts.list/1` no longer discovers an
  # embedded `mounts/<name>/` folder (config truth, `icms:` only), and
  # `MemoryProposal.check_target/2`'s `Mounts.mount_for/2` can only
  # attribute a page to a REGISTERED, external (absolute-rooted) mount — so
  # any test that actually EXECUTES an `apply_page_content` needs one of
  # these, and its `target_path` must be the mounted ICM's absolute path,
  # never the old `"mounts/w/..."` workspace-relative literal (mirrors
  # `Valea.QueueTest`'s identically-named helper).
  defp mount_primary!(workspace, pages \\ %{}) do
    default_pages = %{"Pricing/Current Pricing.md" => "# Current Pricing\n\nCHF 100\n"}
    AgentCase.mount_test_icm!(workspace, name: "Primary", pages: Map.merge(default_pages, pages))
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

    test "a memory_update item applies the edit and returns appliedPath with draftPath nil", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("m1")
      icm = mount_primary!(workspace)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      old = File.read!(target)
      base = :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)
      write_pending_memory(workspace, id, target, base, "# Pricing\n\n150\n")

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => true, "data" => %{"appliedPath" => applied_path, "draftPath" => nil}} =
               rpc(
                 "approve_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation},
                 ["draftPath", "appliedPath"]
               )

      assert applied_path == target
      assert File.read!(target) == "# Pricing\n\n150\n"
      assert File.exists?(Path.join([workspace, "queue", "approved", id <> ".json"]))
    end

    test "a hash-mismatch memory_update item surfaces apply_conflict and stays pending", %{
      workspace: workspace,
      generation: generation
    } do
      id = run_id("m2")
      icm = mount_primary!(workspace)
      target = Path.join(icm.root, "Pricing/Current Pricing.md")
      old = File.read!(target)
      write_pending_memory(workspace, id, target, String.duplicate("0", 64), "# clobber\n")

      assert %{"success" => true, "data" => %{"revision" => revision}} =
               rpc("get_queue_item", %{"runId" => id}, ["item", "revision"])

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "approve_queue_item",
                 %{"runId" => id, "revision" => revision, "generation" => generation},
                 ["draftPath", "appliedPath"]
               )

      assert inspect(errors) =~ "apply_conflict"
      assert File.read!(target) == old
      assert File.exists?(Path.join([workspace, "queue", "pending", id <> ".json"]))
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
