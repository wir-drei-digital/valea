defmodule Valea.ICMWriteTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM
  alias Valea.Markdown.ProseMirror

  # Post-3.2, `Valea.Mounts.list/1` is config truth over `icms:` only — a
  # fresh workspace seeds no mount at all (`Manager.create/2` still
  # physically scaffolds a legacy `mounts/<slug>` starter folder, but never
  # registers it under `icms:`, so `Mounts.list/1` can't see it). This whole
  # suite's fixtures assume the legacy scaffold's rich seed content (Offers/,
  # Policies/, Pricing/, Templates/, Clients/, Workflows/ — including the
  # `Workflows/*.md` `path:` frontmatter convention every
  # rename/reference-rewrite assertion below addresses), so it's copied
  # fresh into an EXTERNAL tmp dir and mounted via `Mounts.mount/2`, landing
  # at mount key "primary" (name "Primary" slugifies to "primary" —
  # `Valea.Workspace.Scaffold.slugify/1`), exactly the vocabulary every path
  # below addresses (via `icm.root`, never a `mounts/primary/...`
  # workspace-relative literal).
  defp mount_starter_icm!(workspace, name \\ "Primary") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-starter-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(
      Path.join(:code.priv_dir(:valea), "legacy_workspace_template/mounts/starter"),
      dir
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})

    {:ok, %{mount_key: mount_key, id: id}} = Mounts.mount(workspace, dir)
    %{mount_key: mount_key, id: id, root: Mounts.mount_by_key(workspace, mount_key).root}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")
    icm = mount_starter_icm!(ws.path)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path, icm: icm}
  end

  defp load(path) do
    {:ok, page} = ICM.page(path)
    page
  end

  test "page returns hash and prosemirror", %{icm: icm} do
    page = load(Path.join(icm.root, "Offers/Founder Coaching Package.md"))
    assert page.hash =~ ~r/^[0-9a-f]{64}$/
    assert %{"type" => "doc"} = page.prosemirror
  end

  test "save_page round-trips an edit and returns a new hash", %{icm: icm} do
    page = load(Path.join(icm.root, "Policies/No Medical Advice.md"))
    {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
    {:ok, %{hash: new_hash}} = ICM.save_page(page.path, pm, page.hash)
    refute new_hash == page.hash
    assert load(page.path).content =~ "One more line."
  end

  test "save_page rejects a stale base hash", %{icm: icm} do
    page = load(Path.join(icm.root, "Policies/No Medical Advice.md"))
    {:ok, pm} = ProseMirror.from_markdown("# Changed\n")
    {:ok, _} = ICM.save_page(page.path, pm, page.hash)
    assert {:error, :page_changed} = ICM.save_page(page.path, pm, page.hash)
  end

  test "save_page enforces containment and existence", %{icm: icm} do
    {:ok, pm} = ProseMirror.from_markdown("# X\n")

    assert {:error, :outside_workspace} =
             ICM.save_page("../logs/audit.jsonl", pm, String.duplicate("0", 64))

    assert {:error, :not_found} =
             ICM.save_page(
               Path.join(icm.root, "Offers/Nope.md"),
               pm,
               String.duplicate("0", 64)
             )
  end

  test "unchanged save is byte-identical (determinism through the write path)", %{icm: icm} do
    page = load(Path.join(icm.root, "Offers/Founder Coaching Package.md"))
    {:ok, %{hash: h2}} = ICM.save_page(page.path, page.prosemirror, page.hash)
    assert h2 == page.hash
  end

  test "create_page seeds title and appends .md", %{icm: icm} do
    {:ok, %{path: path}} = ICM.create_page(Path.join(icm.root, "Decisions"), "Pricing Call")
    assert path == Path.join(icm.root, "Decisions/Pricing Call.md")
    assert load(path).content == "# Pricing Call"
  end

  test "create_page's seed round-trips byte-identically through the write path (determinism contract)",
       %{icm: icm} do
    {:ok, %{path: path}} = ICM.create_page(Path.join(icm.root, "Decisions"), "Pricing Call")
    content = load(path).content

    assert {:ok, pm} = ProseMirror.from_markdown(content)
    assert {:ok, ^content} = ProseMirror.to_markdown(pm)
  end

  test "create_page at mount root, create_folder, duplicate and invalid names", %{icm: icm} do
    assert {:ok, %{path: scratch_path}} = ICM.create_page(icm.root, "Scratch")
    assert scratch_path == Path.join(icm.root, "Scratch.md")

    assert {:ok, %{path: projects_path}} = ICM.create_folder(icm.root, "Projects")
    assert projects_path == Path.join(icm.root, "Projects")

    assert {:error, :already_exists} = ICM.create_folder(icm.root, "Projects")
    assert {:error, :already_exists} = ICM.create_page(icm.root, "Scratch")

    for bad <- ["", "  ", "a/b", "a\\b", ".hidden"] do
      assert {:error, :name_invalid} = ICM.create_page(icm.root, bad)
      assert {:error, :name_invalid} = ICM.create_folder(icm.root, bad)
    end

    assert {:error, :outside_workspace} = ICM.create_page("..", "x")
  end

  test "create_page normalizes unicode and trims whitespace into the written path", %{icm: icm} do
    {:ok, %{path: path}} = ICM.create_page(icm.root, " Café ")
    assert path == Path.join(icm.root, "Café.md")
    assert path == String.normalize(path, :nfc)
    assert load(path).title == "Café"
  end

  test "create under a file parent returns name_invalid, and x. gets a single extension", %{
    icm: icm
  } do
    assert {:error, :name_invalid} =
             ICM.create_page(
               Path.join(icm.root, "Offers/Founder Coaching Package.md"),
               "Child"
             )

    {:ok, %{path: path}} = ICM.create_page(icm.root, "Trailing.")
    assert path == Path.join(icm.root, "Trailing.md")
  end

  test "create_page_from_template substitutes title and date, code fences included", %{icm: icm} do
    File.write!(
      Path.join(icm.root, "Templates/T.md"),
      "# {{title}}\n\nSince {{date}}.\n\n```\n{{title}} in a fence\n```\n\n{{unknown}} stays\n"
    )

    {:ok, %{path: path}} =
      ICM.create_page_from_template(
        Path.join(icm.root, "Clients"),
        "Anna Roth",
        Path.join(icm.root, "Templates/T.md")
      )

    assert path == Path.join(icm.root, "Clients/Anna Roth.md")
    today = Date.utc_today() |> Date.to_iso8601()

    assert File.read!(path) ==
             "# Anna Roth\n\nSince #{today}.\n\n```\nAnna Roth in a fence\n```\n\n{{unknown}} stays\n"
  end

  test "cross-mount template is rejected", %{ws: ws, icm: icm} do
    second_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-second-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(second_dir) end)

    assert {:ok, %{mount_key: mount_key}} = Mounts.create(ws, "second", second_dir)
    # Derive the template path from the EFFECTIVE mount's realpath-resolved
    # root, not the raw tmp path — on macOS the raw `/var/folders/...` tmp
    # path never string-matches the resolved `/private/var/...` root.
    second_root = Mounts.mount_by_key(ws, mount_key).root

    assert {:error, :cross_mount_template} =
             ICM.create_page_from_template(
               Path.join(icm.root, "Clients"),
               "X",
               Path.join(second_root, "Templates/T.md")
             )
  end

  test "create_page_from_template: existing target and bad names are rejected as create_page does",
       %{icm: icm} do
    File.write!(Path.join(icm.root, "Templates/T.md"), "# {{title}}\n")

    assert {:error, :name_invalid} =
             ICM.create_page_from_template(
               Path.join(icm.root, "Clients"),
               "a/b",
               Path.join(icm.root, "Templates/T.md")
             )

    assert {:error, :already_exists} =
             ICM.create_page_from_template(
               Path.join(icm.root, "Clients"),
               "Lea Brunner",
               Path.join(icm.root, "Templates/T.md")
             )
  end

  test "create_page_from_template: an unreadable template is rejected", %{icm: icm} do
    assert {:error, :template_not_found} =
             ICM.create_page_from_template(
               Path.join(icm.root, "Clients"),
               "Ghost",
               Path.join(icm.root, "Templates/Nope.md")
             )
  end

  test "create_page_from_template: page name with {{date}} placeholder stays literal", %{
    icm: icm
  } do
    File.write!(
      Path.join(icm.root, "Templates/Report.md"),
      "# {{title}}\n\nGenerated on {{date}}\n"
    )

    {:ok, %{path: path}} =
      ICM.create_page_from_template(
        Path.join(icm.root, "Clients"),
        "Report {{date}}",
        Path.join(icm.root, "Templates/Report.md")
      )

    today = Date.utc_today() |> Date.to_iso8601()
    content = File.read!(path)

    # The page name should be preserved verbatim in the title
    assert content =~ "# Report {{date}}"
    # The template's {{date}} placeholder should be substituted with the actual date
    assert content =~ "Generated on #{today}"
    # Verify both are present: the literal {{date}} from page name and substituted date
    assert String.contains?(content, ["# Report {{date}}", "Generated on #{today}"])
  end

  defp workflow_page(icm) do
    File.read!(Path.join(icm.root, "Workflows/New Inquiry Triage.md"))
  end

  test "rename a referenced page moves the file and rewrites referencing workflows", %{icm: icm} do
    assert {:ok,
            %{
              path: new_path,
              updated_workflows: ["New Inquiry Triage"]
            }} =
             ICM.rename(
               Path.join(icm.root, "Offers/Founder Coaching Package.md"),
               "Founder Package"
             )

    assert new_path == Path.join(icm.root, "Offers/Founder Package.md")

    refute File.exists?(Path.join(icm.root, "Offers/Founder Coaching Package.md"))
    assert File.exists?(Path.join(icm.root, "Offers/Founder Package.md"))

    page = workflow_page(icm)
    assert page =~ ~s(path: "Offers/Founder Package.md")
    refute page =~ "Offers/Founder Coaching Package.md"
  end

  test "rename to an invalid or already-existing name", %{icm: icm} do
    assert {:error, :name_invalid} =
             ICM.rename(Path.join(icm.root, "Offers/Founder Coaching Package.md"), "a/b")

    assert {:error, :already_exists} =
             ICM.rename(
               Path.join(icm.root, "Offers/Founder Coaching Package.md"),
               "Discovery Call"
             )
  end

  test "renaming a folder containing a referenced page rewrites the workflow", %{icm: icm} do
    assert {:ok, %{path: new_path, updated_workflows: ["New Inquiry Triage"]}} =
             ICM.rename(Path.join(icm.root, "Offers"), "Offerings")

    assert new_path == Path.join(icm.root, "Offerings")

    refute File.exists?(Path.join(icm.root, "Offers"))

    assert File.exists?(Path.join(icm.root, "Offerings/Founder Coaching Package.md"))

    page = workflow_page(icm)
    assert page =~ ~s(path: "Offerings/Founder Coaching Package.md")
    refute page =~ "Offers/Founder Coaching Package.md"
  end

  test "renaming a folder does not corrupt references to a sibling folder whose name is a prefix superset",
       %{icm: icm} do
    {:ok, %{path: extra_path}} = ICM.create_folder(icm.root, "Offers Extra")
    assert extra_path == Path.join(icm.root, "Offers Extra")

    {:ok, %{path: sidecar_path}} = ICM.create_page(extra_path, "Sidecar")
    assert sidecar_path == Path.join(icm.root, "Offers Extra/Sidecar.md")

    workflow_path = Path.join(icm.root, "Workflows/New Inquiry Triage.md")

    File.write!(
      workflow_path,
      File.read!(workflow_path) <>
        "\n  - id: sidecar\n    type: icm\n    path: \"Offers Extra/Sidecar.md\"\n"
    )

    assert {:ok, %{path: offerings_path}} = ICM.rename(Path.join(icm.root, "Offers"), "Offerings")
    assert offerings_path == Path.join(icm.root, "Offerings")

    page = workflow_page(icm)
    assert page =~ ~s(path: "Offerings/Founder Coaching Package.md")
    assert page =~ ~s(path: "Offers Extra/Sidecar.md")
    refute page =~ "Offerings Extra/Sidecar.md"
  end

  test "renaming a folder rewrites wildcard workflow references to it", %{icm: icm} do
    session_prep = fn -> File.read!(Path.join(icm.root, "Workflows/Session Prep Brief.md")) end

    post_session = fn ->
      File.read!(Path.join(icm.root, "Workflows/Post-Session Follow-up.md"))
    end

    assert session_prep.() =~ ~s(path: "Clients/*")
    assert post_session.() =~ ~s(path: "Clients/*")

    assert {:ok, %{path: new_path, updated_workflows: updated_workflows}} =
             ICM.rename(Path.join(icm.root, "Clients"), "Customers")

    assert new_path == Path.join(icm.root, "Customers")

    assert "Session Prep Brief" in updated_workflows
    assert "Post-Session Follow-up" in updated_workflows

    refute File.exists?(Path.join(icm.root, "Clients"))
    assert File.exists?(Path.join(icm.root, "Customers"))

    assert session_prep.() =~ ~s(path: "Customers/*")
    refute session_prep.() =~ "Clients/*"
    assert post_session.() =~ ~s(path: "Customers/*")
    refute post_session.() =~ "Clients/*"
  end

  test "delete a page removes it and leaves workflows untouched", %{icm: icm} do
    before_page = workflow_page(icm)

    assert {:ok, %{deleted: true}} = ICM.delete(Path.join(icm.root, "Clients/Lea Brunner.md"))
    refute File.exists?(Path.join(icm.root, "Clients/Lea Brunner.md"))
    assert workflow_page(icm) == before_page
  end

  test "delete a folder recursively removes its contents", %{icm: icm} do
    assert {:ok, %{deleted: true}} = ICM.delete(Path.join(icm.root, "Templates"))
    refute File.exists?(Path.join(icm.root, "Templates"))
  end

  test "delete a non-existent path returns not_found", %{icm: icm} do
    assert {:error, :not_found} = ICM.delete(Path.join(icm.root, "Offers/Nope.md"))
  end

  describe "external mounts (A2-T5b)" do
    defp external_icm!(name) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Manifest.write!(dir, %{
        id: Ecto.UUID.generate(),
        name: name,
        description: ""
      })

      dir
    end

    setup %{ws: ws} do
      ext = external_icm!("Ext")
      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/External.md"), "# External Page\n")
      {:ok, _} = Mounts.mount(ws, ext)

      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))
      %{mount: m}
    end

    test "save_page round-trips an edit and returns a new hash, guarded by base_hash", %{
      mount: m
    } do
      page_path = Path.join(m.root, "Offers/External.md")
      page = load(page_path)

      {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
      {:ok, %{hash: new_hash}} = ICM.save_page(page_path, pm, page.hash)
      refute new_hash == page.hash
      assert load(page_path).content =~ "One more line."

      # A stale base_hash is rejected — the guard applies to external pages
      # exactly as it does to embedded ones.
      assert {:error, :page_changed} = ICM.save_page(page_path, pm, page.hash)
    end

    test "create_page/create_folder at the external mount's own root", %{mount: m} do
      assert {:ok, %{path: page_path}} = ICM.create_page(m.root, "Scratch")
      assert page_path == Path.join(m.root, "Scratch.md")
      assert load(page_path).content == "# Scratch"

      assert {:ok, %{path: folder_path}} = ICM.create_folder(m.root, "Projects")
      assert folder_path == Path.join(m.root, "Projects")
      assert File.dir?(folder_path)

      assert {:error, :already_exists} = ICM.create_folder(m.root, "Projects")
    end
  end
end
