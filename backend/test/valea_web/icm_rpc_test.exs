defmodule ValeaWeb.IcmRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Workspace.Manager

  # The starter-mount's rich seed content (Offers/, Templates/, Workflows/,
  # ...) now lives only under the LEGACY (v4, all-are-mounts) template —
  # `priv/workspace_template` (v5) no longer ships a starter mount at all.
  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY
  # (no more filesystem-glob discovery of an embedded `mounts/<name>`), so
  # instead of relying on a legacy-scaffold-seeded folder `list/1` can no
  # longer see, `setup` mounts a REAL EXTERNAL ICM (via
  # `AgentCase.mount_test_icm!/2`) carrying this same content, read straight
  # off disk — mirrors `Valea.Markdown.DeterminismTest`'s identical
  # `@template`/filter. Every mount is external now, so every path this
  # suite addresses is the ICM's ABSOLUTE resolved path (`icm.root`-relative,
  # via `Path.join/2`), never the old `mounts/primary/...`
  # workspace-relative literal — see `Valea.ICM`'s `mount_root_for/1` and
  # `Valea.Mounts.mount_for/2`, both of which only accept that vocabulary
  # for an external mount now.
  @template Path.join(:code.priv_dir(:valea), "legacy_workspace_template/mounts/starter")

  defp seed_pages do
    @template
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      rel = Path.relative_to(path, @template)
      rel in ["AGENTS.md", "CLAUDE.md"] or String.starts_with?(rel, "prompts/")
    end)
    |> Map.new(fn path -> {Path.relative_to(path, @template), File.read!(path)} end)
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

    # Legacy path-based `Manager.create/2` (v4) — called directly rather
    # than through the `create_workspace` RPC, which is now the C9 id-based
    # surface (`Manager.create/1`, v5, no `mounts/`). Either scaffold works
    # here since the ICM content this suite exercises comes from the
    # EXTERNAL mount below, not from anything the scaffold itself seeds.
    parent = Path.join(dir, "workspaces")
    {:ok, ws} = Manager.create(parent, "Primary")

    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary", pages: seed_pages())

    %{workspace: ws.path, icm: icm}
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

    test "returns one entry per mount, grouped, with string keys all the way down", %{icm: icm} do
      assert %{"success" => true, "data" => %{"mounts" => [mount]}} =
               rpc("icm_tree", %{}, @mount_fields)

      assert mount["mount"] == icm.mount_key
      assert mount["title"] == "Primary"
      assert mount["rootRel"] == icm.root
      assert is_list(mount["tree"])

      offers = Enum.find(mount["tree"], &(&1["name"] == "Offers"))
      assert offers["type"] == "folder"
      assert offers["path"] == Path.join(icm.root, "Offers")
      assert is_list(offers["children"])

      page = Enum.find(offers["children"], &(&1["name"] == "Founder Coaching Package"))
      assert page["type"] == "page"
      assert page["path"] == Path.join(icm.root, "Offers/Founder Coaching Package.md")

      assert page["uri"] ==
               "icm://" <> Path.join(icm.root, "Offers/Founder Coaching Package.md")
    end

    test "groups per enabled mount, sorted by name, each with its own title", %{
      workspace: workspace,
      icm: icm
    } do
      secondary =
        AgentCase.mount_test_icm!(workspace,
          name: "Secondary",
          id: "efe438ce-209f-4beb-8b14-16bb6483bf82"
        )

      assert %{"success" => true, "data" => %{"mounts" => mounts}} =
               rpc("icm_tree", %{}, @mount_fields)

      assert Enum.map(mounts, & &1["mount"]) == [icm.mount_key, secondary.mount_key]

      secondary_group = Enum.find(mounts, &(&1["mount"] == secondary.mount_key))
      assert secondary_group["title"] == "Secondary"
      assert secondary_group["rootRel"] == secondary.root

      # `mount_test_icm!/2` always seeds an AGENTS.md (every real external
      # ICM ships one) — with no other pages passed, that's the only node
      # in the tree: the "no ICM content" equivalent of the pre-3.2 empty
      # embedded-mount fixture.
      assert Enum.map(secondary_group["tree"], & &1["name"]) == ["AGENTS"]
    end
  end

  describe "save_icm_page" do
    test "mutates and persists: load, append paragraph, save, re-fetch, verify", %{icm: icm} do
      path = Path.join(icm.root, "Offers/Discovery Call.md")

      # Load the original page
      assert %{"success" => true, "data" => page} = rpc("icm_page", %{"path" => path})

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
                   "path" => path,
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
      assert %{"success" => true, "data" => refetched} = rpc("icm_page", %{"path" => path})

      # Verify the content was persisted and contains the added text
      refetched_content = refetched["content"]
      assert is_binary(refetched_content)
      assert refetched_content =~ "Added by rpc test."

      # Verify the hash matches the saved hash
      assert refetched["hash"] == saved_hash
    end

    test "stale base hash surfaces page_changed", %{icm: icm} do
      path = Path.join(icm.root, "Offers/Discovery Call.md")

      assert %{"success" => true, "data" => page} = rpc("icm_page", %{"path" => path})

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => path,
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => "deadbeef"
                 },
                 ["hash", "savedAt"]
               )

      assert inspect(errors) =~ "page_changed"
    end

    test "a stale generation surfaces workspace_changed and does not save", %{icm: icm} do
      path = Path.join(icm.root, "Offers/Discovery Call.md")

      assert %{"success" => true, "data" => page} = rpc("icm_page", %{"path" => path})

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => path,
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => page["hash"],
                   "generation" => 999_999
                 },
                 ["hash", "savedAt"]
               )

      assert inspect(errors) =~ "workspace_changed"

      # Untouched: re-fetching still shows the original hash.
      assert %{"success" => true, "data" => refetched} = rpc("icm_page", %{"path" => path})

      assert refetched["hash"] == page["hash"]
    end

    test "a matching generation saves normally", %{icm: icm} do
      assert %{"success" => true, "data" => %{"generation" => generation}} =
               rpc("get_workspace", %{})

      path = Path.join(icm.root, "Offers/Discovery Call.md")

      assert %{"success" => true, "data" => page} = rpc("icm_page", %{"path" => path})

      assert %{"success" => true, "data" => saved} =
               rpc(
                 "save_icm_page",
                 %{
                   "path" => path,
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
    test "create_icm_page returns the new path", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page",
                 %{"parentPath" => Path.join(icm.root, "Offers"), "name" => "New Offer"},
                 ["path"]
               )

      assert path == Path.join(icm.root, "Offers/New Offer.md")
    end

    test "create_icm_page at the mount root succeeds", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page",
                 %{"parentPath" => icm.root, "name" => "Root Test"},
                 ["path"]
               )

      assert path == Path.join(icm.root, "Root Test.md")
    end

    test "create_icm_folder returns the new path", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_folder",
                 %{"parentPath" => Path.join(icm.root, "Offers"), "name" => "New Section"},
                 ["path"]
               )

      assert path == Path.join(icm.root, "Offers/New Section")
    end

    test "create_icm_page_from_template substitutes title and date", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page_from_template",
                 %{
                   "parentPath" => Path.join(icm.root, "Clients"),
                   "name" => "Anna Roth",
                   "templatePath" => Path.join(icm.root, "Templates/Client.md")
                 },
                 ["path"]
               )

      assert path == Path.join(icm.root, "Clients/Anna Roth.md")

      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"path" => path})

      assert page["content"] =~ "# Anna Roth"
      assert page["content"] =~ Date.utc_today() |> Date.to_iso8601()
    end

    test "create_icm_page_from_template rejects a cross-mount template", %{
      workspace: workspace,
      icm: icm
    } do
      secondary =
        AgentCase.mount_test_icm!(workspace,
          name: "Secondary",
          id: "efe438ce-209f-4beb-8b14-16bb6483bf82",
          pages: %{"Templates/T.md" => "# {{title}}\n"}
        )

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_icm_page_from_template",
                 %{
                   "parentPath" => Path.join(icm.root, "Clients"),
                   "name" => "X",
                   "templatePath" => Path.join(secondary.root, "Templates/T.md")
                 },
                 ["path"]
               )

      assert inspect(errors) =~ "cross_mount_template"
    end

    test "rename_icm_entry of a referenced page reports the updated workflows", %{icm: icm} do
      assert %{"success" => true, "data" => data} =
               rpc(
                 "rename_icm_entry",
                 %{
                   "path" => Path.join(icm.root, "Templates/Follow-up Email.md"),
                   "newName" => "Follow-up Note"
                 },
                 ["path", "updatedWorkflows"]
               )

      assert data["path"] == Path.join(icm.root, "Templates/Follow-up Note.md")
      assert is_list(data["updatedWorkflows"])
      assert data["updatedWorkflows"] != []
      assert "Post-Session Follow-up" in data["updatedWorkflows"]
    end

    test "delete_icm_entry returns deleted: true", %{icm: icm} do
      assert %{"success" => true, "data" => %{"deleted" => true}} =
               rpc(
                 "delete_icm_entry",
                 %{"path" => Path.join(icm.root, "Offers/Discovery Call.md")},
                 ["deleted"]
               )
    end

    test "icm_entry_references lists referencing workflows", %{icm: icm} do
      assert %{"success" => true, "data" => %{"workflows" => workflows}} =
               rpc(
                 "icm_entry_references",
                 %{"path" => Path.join(icm.root, "Templates/Follow-up Email.md")},
                 [%{"workflows" => ["file", "name"]}]
               )

      assert is_list(workflows)
      assert Enum.all?(workflows, &(is_binary(&1["file"]) and is_binary(&1["name"])))
      assert Enum.any?(workflows, &(&1["name"] == "Post-Session Follow-up"))
    end

    test "icm_entry_references also lists AST-confirmed page backlinks (Task C3)", %{icm: icm} do
      # A real Link node resolving (relative-from-source) to the target —
      # must be confirmed.
      File.write!(
        Path.join(icm.root, "Offers/Backlink Source.md"),
        "# Backlink Source\n\nSee the [template](<../Templates/Follow-up Email.md>) for details.\n"
      )

      # A bare prose mention of the same filename — never a Link node, must
      # NOT be confirmed.
      File.write!(
        Path.join(icm.root, "Offers/Not A Link.md"),
        "# Not A Link\n\nTemplates/Follow-up Email.md is mentioned in prose only.\n"
      )

      assert %{"success" => true, "data" => %{"workflows" => workflows, "pages" => pages}} =
               rpc(
                 "icm_entry_references",
                 %{"path" => Path.join(icm.root, "Templates/Follow-up Email.md")},
                 [
                   %{"workflows" => ["file", "name"]},
                   %{"pages" => ["sourcePath", "mount", "linkText"]}
                 ]
               )

      assert is_list(workflows)
      assert is_list(pages)

      refute Enum.any?(pages, &(&1["sourcePath"] == Path.join(icm.root, "Offers/Not A Link.md")))

      hit =
        Enum.find(pages, &(&1["sourcePath"] == Path.join(icm.root, "Offers/Backlink Source.md")))

      assert hit != nil
      assert hit["mount"] == icm.mount_key
      assert hit["linkText"] == "template"
    end
  end

  describe "icm_search" do
    # `results`/`skipped` are the `:search` action's own `constraints
    # fields: [...]` typed return (Task C2) — `results` nests field
    # selection into an `Array<TypedMap>`, same shape as `icm_tree`'s
    # `mounts` above.
    @search_fields [%{"results" => ["path", "mount", "title", "snippet", "terms"]}, "skipped"]

    test "returns camelCased results with mount name for a seeded term", %{icm: icm} do
      assert %{"success" => true, "data" => %{"results" => results, "skipped" => skipped}} =
               rpc("icm_search", %{"query" => "founder coaching"}, @search_fields)

      assert is_list(skipped)

      hit =
        Enum.find(
          results,
          &(&1["path"] == Path.join(icm.root, "Offers/Founder Coaching Package.md"))
        )

      assert hit["mount"] == icm.mount_key
      assert hit["title"] == "Founder Coaching Package"
      assert is_binary(hit["snippet"])
      assert hit["terms"] == ["founder", "coaching"]
    end

    test "mount argument filters Mounts.enabled to that one mount before scanning", %{icm: icm} do
      assert %{"success" => true, "data" => %{"results" => results}} =
               rpc(
                 "icm_search",
                 %{"query" => "coaching", "mount" => icm.mount_key},
                 @search_fields
               )

      assert results != []
      assert Enum.all?(results, &(&1["mount"] == icm.mount_key))
    end

    test "an unknown mount name yields no results, never an error" do
      assert %{"success" => true, "data" => %{"results" => results}} =
               rpc(
                 "icm_search",
                 %{"query" => "coaching", "mount" => "does-not-exist"},
                 @search_fields
               )

      assert results == []
    end
  end

  describe "icm_paths_exist" do
    @paths_exist_fields [%{"results" => ["path", "exists"]}]

    test "true only for a real page inside an enabled mount; shell/traversal paths are false, never an error",
         %{icm: icm} do
      real_path = Path.join(icm.root, "Pricing/Current Pricing.md")
      # Escapes the mount root via a literal `..` segment — same shape the
      # pre-3.2 fixture used to escape the workspace, now aimed at the
      # mount's own containment boundary instead (`Valea.Paths.resolve_real/2`
      # collapses it OUTSIDE `icm.root`, so this must still resolve false,
      # never an error).
      traversal_path = Path.join(icm.root, "../secrets/x")

      assert %{"success" => true, "data" => %{"results" => results}} =
               rpc(
                 "icm_paths_exist",
                 %{
                   "paths" => [
                     real_path,
                     "AGENTS.md",
                     traversal_path
                   ]
                 },
                 @paths_exist_fields
               )

      assert results == [
               %{"path" => real_path, "exists" => true},
               %{"path" => "AGENTS.md", "exists" => false},
               %{"path" => traversal_path, "exists" => false}
             ]
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
