defmodule Valea.ICMWriteTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM
  alias Valea.Markdown.ProseMirror

  # `Valea.Mounts.list/1` is config truth over `icms:` only — a fresh v5
  # workspace seeds no mount at all. This whole suite's fixtures assume the
  # old starter mount's rich seed content (Offers/, Policies/, Pricing/,
  # Templates/, Clients/), preserved under `test/fixtures/starter_icm/`
  # (Task 11.3), so it's copied fresh into an EXTERNAL tmp dir and mounted
  # via `Mounts.mount/2`, landing at mount key "primary" (name "Primary"
  # slugifies to "primary" — `Valea.Workspace.Scaffold.slugify/1`).
  #
  # Task 4.2 re-key: every `Valea.ICM` function now takes `(mount_key,
  # rel_path)`, `rel_path` relative to `icm.root` — `""` addresses the
  # mount's own root.
  defp mount_starter_icm!(workspace, name \\ "Primary") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-starter-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(Path.expand("../fixtures/starter_icm", __DIR__), dir)

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
    {:ok, ws} = Manager.create("Primary")
    icm = mount_starter_icm!(ws.path)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path, icm: icm}
  end

  defp load(mount_key, rel_path) do
    {:ok, page} = ICM.page(mount_key, rel_path)
    page
  end

  test "page returns hash and prosemirror", %{icm: icm} do
    page = load(icm.mount_key, "Offers/Founder Coaching Package.md")
    assert page.hash =~ ~r/^[0-9a-f]{64}$/
    assert %{"type" => "doc"} = page.prosemirror
  end

  test "save_page round-trips an edit and returns a new hash", %{icm: icm} do
    page = load(icm.mount_key, "Policies/No Medical Advice.md")
    {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
    {:ok, %{hash: new_hash}} = ICM.save_page(icm.mount_key, page.path, pm, page.hash)
    refute new_hash == page.hash
    assert load(icm.mount_key, page.path).content =~ "One more line."
  end

  test "save_page rejects a stale base hash", %{icm: icm} do
    page = load(icm.mount_key, "Policies/No Medical Advice.md")
    {:ok, pm} = ProseMirror.from_markdown("# Changed\n")
    {:ok, _} = ICM.save_page(icm.mount_key, page.path, pm, page.hash)
    assert {:error, :page_changed} = ICM.save_page(icm.mount_key, page.path, pm, page.hash)
  end

  test "save_page enforces containment and existence", %{icm: icm} do
    {:ok, pm} = ProseMirror.from_markdown("# X\n")

    assert {:error, :outside_workspace} =
             ICM.save_page(icm.mount_key, "../logs/audit.jsonl", pm, String.duplicate("0", 64))

    assert {:error, :not_found} =
             ICM.save_page(
               icm.mount_key,
               "Offers/Nope.md",
               pm,
               String.duplicate("0", 64)
             )
  end

  test "unchanged save is byte-identical (determinism through the write path)", %{icm: icm} do
    page = load(icm.mount_key, "Offers/Founder Coaching Package.md")
    {:ok, %{hash: h2}} = ICM.save_page(icm.mount_key, page.path, page.prosemirror, page.hash)
    assert h2 == page.hash
  end

  test "create_page seeds title and appends .md", %{icm: icm} do
    {:ok, %{path: path}} = ICM.create_page(icm.mount_key, "Decisions", "Pricing Call")
    assert path == "Decisions/Pricing Call.md"
    assert load(icm.mount_key, path).content == "# Pricing Call"
  end

  test "create_page's seed round-trips byte-identically through the write path (determinism contract)",
       %{icm: icm} do
    {:ok, %{path: path}} = ICM.create_page(icm.mount_key, "Decisions", "Pricing Call")
    content = load(icm.mount_key, path).content

    assert {:ok, pm} = ProseMirror.from_markdown(content)
    assert {:ok, ^content} = ProseMirror.to_markdown(pm)
  end

  test "create_page at mount root, create_folder, duplicate and invalid names", %{icm: icm} do
    assert {:ok, %{path: scratch_path}} = ICM.create_page(icm.mount_key, "", "Scratch")
    assert scratch_path == "Scratch.md"

    assert {:ok, %{path: projects_path}} = ICM.create_folder(icm.mount_key, "", "Projects")
    assert projects_path == "Projects"

    assert {:error, :already_exists} = ICM.create_folder(icm.mount_key, "", "Projects")
    assert {:error, :already_exists} = ICM.create_page(icm.mount_key, "", "Scratch")

    for bad <- ["", "  ", "a/b", "a\\b", ".hidden"] do
      assert {:error, :name_invalid} = ICM.create_page(icm.mount_key, "", bad)
      assert {:error, :name_invalid} = ICM.create_folder(icm.mount_key, "", bad)
    end

    assert {:error, :outside_workspace} = ICM.create_page(icm.mount_key, "..", "x")
  end

  test "create_page normalizes unicode and trims whitespace into the written path", %{icm: icm} do
    {:ok, %{path: path}} = ICM.create_page(icm.mount_key, "", " Café ")
    assert path == "Café.md"
    assert path == String.normalize(path, :nfc)
    assert load(icm.mount_key, path).title == "Café"
  end

  test "create under a file parent returns name_invalid, and x. gets a single extension", %{
    icm: icm
  } do
    assert {:error, :name_invalid} =
             ICM.create_page(
               icm.mount_key,
               "Offers/Founder Coaching Package.md",
               "Child"
             )

    {:ok, %{path: path}} = ICM.create_page(icm.mount_key, "", "Trailing.")
    assert path == "Trailing.md"
  end

  test "create_page_from_template substitutes title and date, code fences included", %{icm: icm} do
    File.write!(
      Path.join(icm.root, "Templates/T.md"),
      "# {{title}}\n\nSince {{date}}.\n\n```\n{{title}} in a fence\n```\n\n{{unknown}} stays\n"
    )

    {:ok, %{path: path}} =
      ICM.create_page_from_template(
        icm.mount_key,
        "Clients",
        "Anna Roth",
        icm.mount_key,
        "Templates/T.md"
      )

    assert path == "Clients/Anna Roth.md"
    today = Date.utc_today() |> Date.to_iso8601()

    assert File.read!(Path.join(icm.root, path)) ==
             "# Anna Roth\n\nSince #{today}.\n\n```\nAnna Roth in a fence\n```\n\n{{unknown}} stays\n"
  end

  test "cross-mount template is rejected", %{ws: ws, icm: icm} do
    second_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-second-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(second_dir) end)

    assert {:ok, %{mount_key: second_key}} = Mounts.create(ws, "second", second_dir)

    assert {:error, :cross_mount_template} =
             ICM.create_page_from_template(
               icm.mount_key,
               "Clients",
               "X",
               second_key,
               "Templates/T.md"
             )
  end

  test "create_page_from_template: existing target and bad names are rejected as create_page does",
       %{icm: icm} do
    File.write!(Path.join(icm.root, "Templates/T.md"), "# {{title}}\n")

    assert {:error, :name_invalid} =
             ICM.create_page_from_template(
               icm.mount_key,
               "Clients",
               "a/b",
               icm.mount_key,
               "Templates/T.md"
             )

    assert {:error, :already_exists} =
             ICM.create_page_from_template(
               icm.mount_key,
               "Clients",
               "Lea Brunner",
               icm.mount_key,
               "Templates/T.md"
             )
  end

  test "create_page_from_template: an unreadable template is rejected", %{icm: icm} do
    assert {:error, :template_not_found} =
             ICM.create_page_from_template(
               icm.mount_key,
               "Clients",
               "Ghost",
               icm.mount_key,
               "Templates/Nope.md"
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
        icm.mount_key,
        "Clients",
        "Report {{date}}",
        icm.mount_key,
        "Templates/Report.md"
      )

    today = Date.utc_today() |> Date.to_iso8601()
    content = File.read!(Path.join(icm.root, path))

    # The page name should be preserved verbatim in the title
    assert content =~ "# Report {{date}}"
    # The template's {{date}} placeholder should be substituted with the actual date
    assert content =~ "Generated on #{today}"
    # Verify both are present: the literal {{date}} from page name and substituted date
    assert String.contains?(content, ["# Report {{date}}", "Generated on #{today}"])
  end

  test "rename to an invalid or already-existing name", %{icm: icm} do
    assert {:error, :name_invalid} =
             ICM.rename(icm.mount_key, "Offers/Founder Coaching Package.md", "a/b")

    assert {:error, :already_exists} =
             ICM.rename(
               icm.mount_key,
               "Offers/Founder Coaching Package.md",
               "Discovery Call"
             )
  end

  test "rename's return map has exactly two keys, path and updated_pages (Spec D §A)", %{
    icm: icm
  } do
    assert {:ok, result} =
             ICM.rename(icm.mount_key, "Offers/Founder Coaching Package.md", "Founder Package")

    assert Enum.sort(Map.keys(result)) == [:path, :updated_pages]
    assert result.path == "Offers/Founder Package.md"
    assert result.updated_pages == []
  end

  test "delete a page removes it", %{icm: icm} do
    assert {:ok, %{deleted: true}} = ICM.delete(icm.mount_key, "Clients/Lea Brunner.md")
    refute File.exists?(Path.join(icm.root, "Clients/Lea Brunner.md"))
  end

  test "delete a folder recursively removes its contents", %{icm: icm} do
    assert {:ok, %{deleted: true}} = ICM.delete(icm.mount_key, "Templates")
    refute File.exists?(Path.join(icm.root, "Templates"))
  end

  test "delete a non-existent path returns not_found", %{icm: icm} do
    assert {:error, :not_found} = ICM.delete(icm.mount_key, "Offers/Nope.md")
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
      {:ok, %{mount_key: ext_key}} = Mounts.mount(ws, ext)

      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == ext_key))
      %{mount: m, mount_key: ext_key}
    end

    test "save_page round-trips an edit and returns a new hash, guarded by base_hash", %{
      mount_key: mount_key
    } do
      page = load(mount_key, "Offers/External.md")

      {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
      {:ok, %{hash: new_hash}} = ICM.save_page(mount_key, page.path, pm, page.hash)
      refute new_hash == page.hash
      assert load(mount_key, page.path).content =~ "One more line."

      # A stale base_hash is rejected — the guard applies to external pages
      # exactly as it does to embedded ones.
      assert {:error, :page_changed} = ICM.save_page(mount_key, page.path, pm, page.hash)
    end

    test "create_page/create_folder at the mount's own root", %{mount: m, mount_key: mount_key} do
      assert {:ok, %{path: page_path}} = ICM.create_page(mount_key, "", "Scratch")
      assert page_path == "Scratch.md"
      assert load(mount_key, page_path).content == "# Scratch"

      assert {:ok, %{path: folder_path}} = ICM.create_folder(mount_key, "", "Projects")
      assert folder_path == "Projects"
      assert File.dir?(Path.join(m.root, folder_path))

      assert {:error, :already_exists} = ICM.create_folder(mount_key, "", "Projects")
    end
  end
end
