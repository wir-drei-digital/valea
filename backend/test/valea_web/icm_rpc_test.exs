defmodule ValeaWeb.IcmRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  # A fresh scaffold (T8) mints its own real mount from the template's rich
  # seed content (Offers/, Templates/, Workflows/, ...) at
  # `mounts/<slug-of-name>`, with `Workflows/*.md` already carrying the
  # mount-relative `path: "<rel>"` frontmatter convention (no `icm/`
  # prefix). Naming the workspace "Primary" lands that mount at exactly
  # `mounts/primary`, the path the RPC layer's ICM actions (resolving
  # through `Valea.Mounts.mount_for/1`) — and every assertion below —
  # address.
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
    rpc("create_workspace", %{"parentDir" => parent, "name" => "Primary"})

    %{parent: parent}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  describe "icm_tree" do
    # The `:tree` action's outer mount-group shape (`mount`/`title`/
    # `rootRel`/`tree`) is now a `constraints fields: [...]` typed return
    # (Task A-T11) — camelCase like every other typed field on this
    # resource, and selected explicitly like `icm_entry_references`'
    # nested `workflows` field below. The per-node `tree` value stays
    # unconstrained (see moduledoc), so nodes inside it keep snake_case,
    # same as pre-A-T11.
    @mount_fields [%{"mounts" => ["mount", "title", "rootRel", "tree"]}]

    test "returns one entry per mount, grouped, with string keys all the way down" do
      assert %{"success" => true, "data" => %{"mounts" => [mount]}} =
               rpc("icm_tree", %{}, @mount_fields)

      assert mount["mount"] == "primary"
      assert mount["title"] == "Primary"
      assert mount["rootRel"] == "mounts/primary"
      assert is_list(mount["tree"])

      offers = Enum.find(mount["tree"], &(&1["name"] == "Offers"))
      assert offers["type"] == "folder"
      assert offers["path"] == "mounts/primary/Offers"
      assert is_list(offers["children"])

      page = Enum.find(offers["children"], &(&1["name"] == "Founder Coaching Package"))
      assert page["type"] == "page"
      assert page["path"] == "mounts/primary/Offers/Founder Coaching Package.md"
      assert page["uri"] == "icm://mounts/primary/Offers/Founder Coaching Package.md"
    end

    test "groups per enabled mount, sorted by name, each with its own title" do
      assert {:ok, %{path: root}} = Manager.current()
      secondary_dir = Path.join([root, "mounts", "secondary"])
      File.mkdir_p!(secondary_dir)

      Manifest.write!(secondary_dir, %{
        id: "id-secondary",
        name: "Secondary",
        description: ""
      })

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("icm_tree", %{}, @mount_fields)

      assert Enum.map(mounts, & &1["mount"]) == ["primary", "secondary"]

      secondary = Enum.find(mounts, &(&1["mount"] == "secondary"))
      assert secondary["title"] == "Secondary"
      assert secondary["rootRel"] == "mounts/secondary"
      assert secondary["tree"] == []
    end
  end

  describe "save_icm_page" do
    test "mutates and persists: load, append paragraph, save, re-fetch, verify" do
      # Load the original page
      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"path" => "mounts/primary/Offers/Discovery Call.md"})

      original_hash = page["hash"]
      assert is_binary(original_hash)
      assert %{"type" => "doc", "content" => content} = page["prosemirror"]
      assert is_list(content)

      # Mutate: append a paragraph node to the prosemirror content
      new_paragraph = %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "text" => "Added by rpc test."}]
      }

      mutated_prosemirror = %{
        "type" => "doc",
        "content" => content ++ [new_paragraph]
      }

      # Save with the original hash and mutated prosemirror
      assert %{"success" => true, "data" => saved} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => "mounts/primary/Offers/Discovery Call.md",
                   "prosemirror" => mutated_prosemirror,
                   "baseHash" => original_hash
                 },
                 ["hash", "savedAt"]
               )

      saved_hash = saved["hash"]
      assert is_binary(saved_hash)
      assert is_binary(saved["savedAt"])
      # Hash must differ after mutation
      assert saved_hash != original_hash

      # Re-fetch the page to verify persistence
      assert %{"success" => true, "data" => refetched} =
               rpc("icm_page", %{"path" => "mounts/primary/Offers/Discovery Call.md"})

      # Verify the content was persisted and contains the added text
      refetched_content = refetched["content"]
      assert is_binary(refetched_content)
      assert refetched_content =~ "Added by rpc test."

      # Verify the hash matches the saved hash
      assert refetched["hash"] == saved_hash
    end

    test "stale base hash surfaces page_changed" do
      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"path" => "mounts/primary/Offers/Discovery Call.md"})

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => "mounts/primary/Offers/Discovery Call.md",
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => "deadbeef"
                 },
                 ["hash", "savedAt"]
               )

      assert inspect(errors) =~ "page_changed"
    end

    test "a stale generation surfaces workspace_changed and does not save" do
      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"path" => "mounts/primary/Offers/Discovery Call.md"})

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => "mounts/primary/Offers/Discovery Call.md",
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => page["hash"],
                   "generation" => 999_999
                 },
                 ["hash", "savedAt"]
               )

      assert inspect(errors) =~ "workspace_changed"

      # Untouched: re-fetching still shows the original hash.
      assert %{"success" => true, "data" => refetched} =
               rpc("icm_page", %{"path" => "mounts/primary/Offers/Discovery Call.md"})

      assert refetched["hash"] == page["hash"]
    end

    test "a matching generation saves normally" do
      assert %{"success" => true, "data" => %{"generation" => generation}} =
               rpc("get_workspace", %{})

      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"path" => "mounts/primary/Offers/Discovery Call.md"})

      assert %{"success" => true, "data" => saved} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => "mounts/primary/Offers/Discovery Call.md",
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => page["hash"],
                   "generation" => generation
                 },
                 ["hash", "savedAt"]
               )

      assert is_binary(saved["hash"])
    end
  end

  describe "create/rename/delete/references" do
    test "create_icm_page returns the new path" do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page",
                 %{"parentPath" => "mounts/primary/Offers", "name" => "New Offer"},
                 ["path"]
               )

      assert path == "mounts/primary/Offers/New Offer.md"
    end

    test "create_icm_page at the mount root succeeds" do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page",
                 %{"parentPath" => "mounts/primary", "name" => "Root Test"},
                 ["path"]
               )

      assert path == "mounts/primary/Root Test.md"
    end

    test "create_icm_folder returns the new path" do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_folder",
                 %{"parentPath" => "mounts/primary/Offers", "name" => "New Section"},
                 ["path"]
               )

      assert path == "mounts/primary/Offers/New Section"
    end

    test "rename_icm_entry of a referenced page reports the updated workflows" do
      assert %{"success" => true, "data" => data} =
               rpc(
                 "rename_icm_entry",
                 %{
                   "path" => "mounts/primary/Templates/Follow-up Email.md",
                   "newName" => "Follow-up Note"
                 },
                 ["path", "updatedWorkflows"]
               )

      assert data["path"] == "mounts/primary/Templates/Follow-up Note.md"
      assert is_list(data["updatedWorkflows"])
      assert data["updatedWorkflows"] != []
      assert "Post-Session Follow-up" in data["updatedWorkflows"]
    end

    test "delete_icm_entry returns deleted: true" do
      assert %{"success" => true, "data" => %{"deleted" => true}} =
               rpc("delete_icm_entry", %{"path" => "mounts/primary/Offers/Discovery Call.md"}, [
                 "deleted"
               ])
    end

    test "icm_entry_references lists referencing workflows" do
      assert %{"success" => true, "data" => %{"workflows" => workflows}} =
               rpc(
                 "icm_entry_references",
                 %{"path" => "mounts/primary/Templates/Follow-up Email.md"},
                 [%{"workflows" => ["file", "name"]}]
               )

      assert is_list(workflows)
      assert Enum.all?(workflows, &(is_binary(&1["file"]) and is_binary(&1["name"])))
      assert Enum.any?(workflows, &(&1["name"] == "Post-Session Follow-up"))
    end
  end

  describe "error mapping helper" do
    test "atom reasons stringify" do
      assert %Valea.Api.Error{code: "page_changed"} =
               Valea.Api.ICM.error_for(:page_changed)
    end

    test "tuple reasons inspect (never crash via to_string/1)" do
      # to_string/1 raises Protocol.UndefinedError on tuples; the helper must
      # fall back to inspect/1 for any non-atom reason.
      assert %Valea.Api.Error{code: code} =
               Valea.Api.ICM.error_for({:conversion_failed, "boom"})

      assert code =~ "conversion_failed"

      assert %Valea.Api.Error{code: rewrite} =
               Valea.Api.ICM.error_for({:rewrite_failed, "wf.yaml", :eacces})

      assert rewrite =~ "rewrite_failed"
    end

    test "no_workspace maps to workspace_not_open" do
      assert %Valea.Api.Error{code: "workspace_not_open"} =
               Valea.Api.ICM.error_for(:no_workspace)
    end
  end
end
