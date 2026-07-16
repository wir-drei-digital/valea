defmodule ValeaWeb.IcmRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Workspace.Manager

  # The starter-mount's rich seed content (Offers/, Templates/, Workflows/,
  # ...) is preserved under `test/fixtures/starter_icm/` (Task 11.3) — a v5
  # hidden workspace (`priv/workspace_template`) ships no starter mount at
  # all. `Valea.Mounts.list/1` is config truth over `icms:` ONLY (no
  # filesystem-glob discovery of an embedded `mounts/<name>`), so `setup`
  # mounts a REAL EXTERNAL ICM (via `AgentCase.mount_test_icm!/2`) carrying
  # this same content, read straight off disk — mirrors
  # `Valea.Markdown.DeterminismTest`'s identical `@template`/filter.
  #
  # Task 4.2 re-key: every ICM RPC action now takes a `mountKey` argument
  # alongside `path` (ICM-relative, relative to `icm.root` — never the old
  # `mounts/primary/...`/absolute literal), and `icm_tree` returns ONE
  # ICM's `{mountKey, title, tree}` instead of an all-mounts grouped
  # envelope.
  @template Path.expand("../fixtures/starter_icm", __DIR__)

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

    {:ok, ws} = Manager.create("Primary")

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

  defp get_generation do
    %{"success" => true, "data" => %{"generation" => generation}} = rpc("get_workspace", %{})
    generation
  end

  describe "icm_tree" do
    @mount_fields ["mountKey", "title", "tree"]

    test "returns one ICM's tree, string keys all the way down", %{icm: icm} do
      generation = get_generation()

      assert %{"success" => true, "data" => mount} =
               rpc(
                 "icm_tree",
                 %{"mountKey" => icm.mount_key, "generation" => generation},
                 @mount_fields
               )

      assert mount["mountKey"] == icm.mount_key
      assert mount["title"] == "Primary"
      assert is_list(mount["tree"])

      offers = Enum.find(mount["tree"], &(&1["name"] == "Offers"))
      assert offers["type"] == "folder"
      assert offers["path"] == "Offers"
      assert is_list(offers["children"])

      page = Enum.find(offers["children"], &(&1["name"] == "Founder Coaching Package"))
      assert page["type"] == "page"
      assert page["path"] == "Offers/Founder Coaching Package.md"
      assert page["uri"] == "icm://Offers/Founder Coaching Package.md"
    end

    test "a second mount's tree is addressed by its own mount key, independently of the first", %{
      workspace: workspace,
      icm: icm
    } do
      secondary =
        AgentCase.mount_test_icm!(workspace,
          name: "Secondary",
          id: "efe438ce-209f-4beb-8b14-16bb6483bf82"
        )

      generation = get_generation()

      assert %{"success" => true, "data" => secondary_mount} =
               rpc(
                 "icm_tree",
                 %{"mountKey" => secondary.mount_key, "generation" => generation},
                 @mount_fields
               )

      assert secondary_mount["mountKey"] == secondary.mount_key
      assert secondary_mount["title"] == "Secondary"

      # `mount_test_icm!/2` always seeds an AGENTS.md (every real external
      # ICM ships one) — with no other pages passed, that's the only node
      # in the tree: the "no ICM content" equivalent of the pre-3.2 empty
      # embedded-mount fixture.
      assert Enum.map(secondary_mount["tree"], & &1["name"]) == ["AGENTS"]

      assert %{"success" => true, "data" => primary_mount} =
               rpc(
                 "icm_tree",
                 %{"mountKey" => icm.mount_key, "generation" => generation},
                 @mount_fields
               )

      assert primary_mount["mountKey"] == icm.mount_key
    end

    test "an unknown mount key surfaces outside_workspace", %{} do
      generation = get_generation()

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "icm_tree",
                 %{"mountKey" => "does-not-exist", "generation" => generation},
                 @mount_fields
               )

      assert inspect(errors) =~ "outside_workspace"
    end

    test "a stale generation surfaces workspace_changed", %{icm: icm} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "icm_tree",
                 %{"mountKey" => icm.mount_key, "generation" => 999_999},
                 @mount_fields
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  describe "save_icm_page" do
    test "mutates and persists: load, append paragraph, save, re-fetch, verify", %{icm: icm} do
      path = "Offers/Discovery Call.md"

      # Load the original page
      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

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
                   "mountKey" => icm.mount_key,
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
      assert %{"success" => true, "data" => refetched} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

      # Verify the content was persisted and contains the added text
      refetched_content = refetched["content"]
      assert is_binary(refetched_content)
      assert refetched_content =~ "Added by rpc test."

      # Verify the hash matches the saved hash
      assert refetched["hash"] == saved_hash
    end

    test "stale base hash surfaces page_changed", %{icm: icm} do
      path = "Offers/Discovery Call.md"

      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "save_icm_page",
                 %{
                   "mountKey" => icm.mount_key,
                   "path" => path,
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => "deadbeef"
                 },
                 ["hash", "savedAt"]
               )

      assert inspect(errors) =~ "page_changed"
    end

    test "a stale generation surfaces workspace_changed and does not save", %{icm: icm} do
      path = "Offers/Discovery Call.md"

      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "save_icm_page",
                 %{
                   "mountKey" => icm.mount_key,
                   "path" => path,
                   "prosemirror" => page["prosemirror"],
                   "baseHash" => page["hash"],
                   "generation" => 999_999
                 },
                 ["hash", "savedAt"]
               )

      assert inspect(errors) =~ "workspace_changed"

      # Untouched: re-fetching still shows the original hash.
      assert %{"success" => true, "data" => refetched} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

      assert refetched["hash"] == page["hash"]
    end

    test "a matching generation saves normally", %{icm: icm} do
      generation = get_generation()

      path = "Offers/Discovery Call.md"

      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

      assert %{"success" => true, "data" => saved} =
               rpc(
                 "save_icm_page",
                 %{
                   "mountKey" => icm.mount_key,
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
                 %{"mountKey" => icm.mount_key, "parentPath" => "Offers", "name" => "New Offer"},
                 ["path"]
               )

      assert path == "Offers/New Offer.md"
    end

    test "create_icm_page at the mount root succeeds", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page",
                 %{"mountKey" => icm.mount_key, "parentPath" => "", "name" => "Root Test"},
                 ["path"]
               )

      assert path == "Root Test.md"
    end

    test "create_icm_folder returns the new path", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_folder",
                 %{
                   "mountKey" => icm.mount_key,
                   "parentPath" => "Offers",
                   "name" => "New Section"
                 },
                 ["path"]
               )

      assert path == "Offers/New Section"
    end

    test "create_icm_page_from_template substitutes title and date", %{icm: icm} do
      assert %{"success" => true, "data" => %{"path" => path}} =
               rpc(
                 "create_icm_page_from_template",
                 %{
                   "mountKey" => icm.mount_key,
                   "parentPath" => "Clients",
                   "name" => "Anna Roth",
                   "templateMountKey" => icm.mount_key,
                   "templatePath" => "Templates/Client.md"
                 },
                 ["path"]
               )

      assert path == "Clients/Anna Roth.md"

      assert %{"success" => true, "data" => page} =
               rpc("icm_page", %{"mountKey" => icm.mount_key, "path" => path})

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
                   "mountKey" => icm.mount_key,
                   "parentPath" => "Clients",
                   "name" => "X",
                   "templateMountKey" => secondary.mount_key,
                   "templatePath" => "Templates/T.md"
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
                   "mountKey" => icm.mount_key,
                   "path" => "Templates/Follow-up Email.md",
                   "newName" => "Follow-up Note"
                 },
                 ["path", "updatedWorkflows"]
               )

      assert data["path"] == "Templates/Follow-up Note.md"
      assert is_list(data["updatedWorkflows"])
      assert data["updatedWorkflows"] != []
      assert "Post-Session Follow-up" in data["updatedWorkflows"]
    end

    test "delete_icm_entry returns deleted: true", %{icm: icm} do
      assert %{"success" => true, "data" => %{"deleted" => true}} =
               rpc(
                 "delete_icm_entry",
                 %{"mountKey" => icm.mount_key, "path" => "Offers/Discovery Call.md"},
                 ["deleted"]
               )
    end

    test "icm_entry_references lists referencing workflows", %{icm: icm} do
      assert %{"success" => true, "data" => %{"workflows" => workflows}} =
               rpc(
                 "icm_entry_references",
                 %{"mountKey" => icm.mount_key, "path" => "Templates/Follow-up Email.md"},
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
                 %{"mountKey" => icm.mount_key, "path" => "Templates/Follow-up Email.md"},
                 [
                   %{"workflows" => ["file", "name"]},
                   %{"pages" => ["sourcePath", "mount", "linkText"]}
                 ]
               )

      assert is_list(workflows)
      assert is_list(pages)

      refute Enum.any?(pages, &(&1["sourcePath"] == "Offers/Not A Link.md"))

      hit = Enum.find(pages, &(&1["sourcePath"] == "Offers/Backlink Source.md"))

      assert hit != nil
      assert hit["mount"] == icm.mount_key
      assert hit["linkText"] == "template"
    end
  end

  describe "icm_search" do
    # `results`/`skipped` are the `:search` action's own `constraints
    # fields: [...]` typed return (Task C2) — `results` nests field
    # selection into an `Array<TypedMap>`, same shape as `icm_tree`'s
    # `mounts` above. `paths_exist` is NOT part of task 4.2's re-key (it
    # stays workspace-scoped, addressing every enabled mount by name) —
    # only each result's `path` changed, from an absolute `icm.root`-joined
    # literal to ICM-relative (mirroring every other ICM RPC surface's
    # `(mount_key, rel_path)` addressing). `icm_search` itself carries an
    # OPTIONAL `mountKey` (Task 5.6): omitted, it scans every enabled
    # mount (unchanged pre-5.6 default); given, it scopes to that PRIMARY
    # ICM plus every ICM it directly declares related (`Mounts.scoped_roots/2`),
    # not just that one mount.
    @search_fields [%{"results" => ["path", "mount", "title", "snippet", "terms"]}, "skipped"]

    test "returns camelCased results with mount name for a seeded term", %{icm: icm} do
      assert %{"success" => true, "data" => %{"results" => results, "skipped" => skipped}} =
               rpc("icm_search", %{"query" => "founder coaching"}, @search_fields)

      assert is_list(skipped)

      hit = Enum.find(results, &(&1["path"] == "Offers/Founder Coaching Package.md"))

      assert hit["mount"] == icm.mount_key
      assert hit["title"] == "Founder Coaching Package"
      assert is_binary(hit["snippet"])
      assert hit["terms"] == ["founder", "coaching"]
    end

    test "mountKey argument scopes to that ICM (plus any declared-related, here none) before scanning",
         %{icm: icm} do
      assert %{"success" => true, "data" => %{"results" => results}} =
               rpc(
                 "icm_search",
                 %{"query" => "coaching", "mountKey" => icm.mount_key},
                 @search_fields
               )

      assert results != []
      assert Enum.all?(results, &(&1["mount"] == icm.mount_key))
    end

    test "an unknown mountKey yields no results, never an error" do
      assert %{"success" => true, "data" => %{"results" => results}} =
               rpc(
                 "icm_search",
                 %{"query" => "coaching", "mountKey" => "does-not-exist"},
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
