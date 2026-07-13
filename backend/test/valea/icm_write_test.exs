defmodule Valea.ICMWriteTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM
  alias Valea.Markdown.ProseMirror

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    # A fresh scaffold (T8) mints its own real mount from the template's rich
    # seed content (Offers/, Workflows/, etc.) at `mounts/<slug-of-name>`, and
    # the template's `Workflows/*.md` already carry the mount-relative
    # `path: "<rel>"` frontmatter convention (no `icm/` prefix) — naming the
    # workspace "Primary" lands that mount at exactly `mounts/primary`, the
    # path every rename/reference assertion below addresses.
    {:ok, _ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  defp load(path) do
    {:ok, page} = ICM.page(path)
    page
  end

  test "page returns hash and prosemirror" do
    page = load("mounts/primary/Offers/Founder Coaching Package.md")
    assert page.hash =~ ~r/^[0-9a-f]{64}$/
    assert %{"type" => "doc"} = page.prosemirror
  end

  test "save_page round-trips an edit and returns a new hash" do
    page = load("mounts/primary/Policies/No Medical Advice.md")
    {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
    {:ok, %{hash: new_hash}} = ICM.save_page(page.path, pm, page.hash)
    refute new_hash == page.hash
    assert load(page.path).content =~ "One more line."
  end

  test "save_page rejects a stale base hash" do
    page = load("mounts/primary/Policies/No Medical Advice.md")
    {:ok, pm} = ProseMirror.from_markdown("# Changed\n")
    {:ok, _} = ICM.save_page(page.path, pm, page.hash)
    assert {:error, :page_changed} = ICM.save_page(page.path, pm, page.hash)
  end

  test "save_page enforces containment and existence" do
    {:ok, pm} = ProseMirror.from_markdown("# X\n")

    assert {:error, :outside_workspace} =
             ICM.save_page("../logs/audit.jsonl", pm, String.duplicate("0", 64))

    assert {:error, :not_found} =
             ICM.save_page("mounts/primary/Offers/Nope.md", pm, String.duplicate("0", 64))
  end

  test "unchanged save is byte-identical (determinism through the write path)" do
    page = load("mounts/primary/Offers/Founder Coaching Package.md")
    {:ok, %{hash: h2}} = ICM.save_page(page.path, page.prosemirror, page.hash)
    assert h2 == page.hash
  end

  test "create_page seeds title and appends .md" do
    {:ok, %{path: path}} = ICM.create_page("mounts/primary/Decisions", "Pricing Call")
    assert path == "mounts/primary/Decisions/Pricing Call.md"
    assert load(path).content == "# Pricing Call"
  end

  test "create_page's seed round-trips byte-identically through the write path (determinism contract)" do
    {:ok, %{path: path}} = ICM.create_page("mounts/primary/Decisions", "Pricing Call")
    content = load(path).content

    assert {:ok, pm} = ProseMirror.from_markdown(content)
    assert {:ok, ^content} = ProseMirror.to_markdown(pm)
  end

  test "create_page at mount root, create_folder, duplicate and invalid names" do
    {:ok, %{path: "mounts/primary/Scratch.md"}} = ICM.create_page("mounts/primary", "Scratch")
    {:ok, %{path: "mounts/primary/Projects"}} = ICM.create_folder("mounts/primary", "Projects")

    assert {:error, :already_exists} = ICM.create_folder("mounts/primary", "Projects")
    assert {:error, :already_exists} = ICM.create_page("mounts/primary", "Scratch")

    for bad <- ["", "  ", "a/b", "a\\b", ".hidden"] do
      assert {:error, :name_invalid} = ICM.create_page("mounts/primary", bad)
      assert {:error, :name_invalid} = ICM.create_folder("mounts/primary", bad)
    end

    assert {:error, :outside_workspace} = ICM.create_page("..", "x")
  end

  test "create_page normalizes unicode and trims whitespace into the written path" do
    {:ok, %{path: path}} = ICM.create_page("mounts/primary", " Café ")
    assert path == "mounts/primary/Café.md"
    assert path == String.normalize(path, :nfc)
    assert load(path).title == "Café"
  end

  test "create under a file parent returns name_invalid, and x. gets a single extension" do
    assert {:error, :name_invalid} =
             ICM.create_page("mounts/primary/Offers/Founder Coaching Package.md", "Child")

    {:ok, %{path: "mounts/primary/Trailing.md"}} = ICM.create_page("mounts/primary", "Trailing.")
  end

  test "create_page_from_template substitutes title and date, code fences included" do
    File.write!(
      Path.join(ws_path(), "mounts/primary/Templates/T.md"),
      "# {{title}}\n\nSince {{date}}.\n\n```\n{{title}} in a fence\n```\n\n{{unknown}} stays\n"
    )

    {:ok, %{path: path}} =
      ICM.create_page_from_template(
        "mounts/primary/Clients",
        "Anna Roth",
        "mounts/primary/Templates/T.md"
      )

    assert path == "mounts/primary/Clients/Anna Roth.md"
    today = Date.utc_today() |> Date.to_iso8601()

    assert File.read!(Path.join(ws_path(), path)) ==
             "# Anna Roth\n\nSince #{today}.\n\n```\nAnna Roth in a fence\n```\n\n{{unknown}} stays\n"
  end

  test "cross-mount template is rejected" do
    assert {:ok, _} = Mounts.create(ws_path(), "second", "second mount")

    assert {:error, :cross_mount_template} =
             ICM.create_page_from_template(
               "mounts/primary/Clients",
               "X",
               "mounts/second/Templates/T.md"
             )
  end

  test "create_page_from_template: existing target and bad names are rejected as create_page does" do
    File.write!(Path.join(ws_path(), "mounts/primary/Templates/T.md"), "# {{title}}\n")

    assert {:error, :name_invalid} =
             ICM.create_page_from_template(
               "mounts/primary/Clients",
               "a/b",
               "mounts/primary/Templates/T.md"
             )

    assert {:error, :already_exists} =
             ICM.create_page_from_template(
               "mounts/primary/Clients",
               "Lea Brunner",
               "mounts/primary/Templates/T.md"
             )
  end

  test "create_page_from_template: an unreadable template is rejected" do
    assert {:error, :template_not_found} =
             ICM.create_page_from_template(
               "mounts/primary/Clients",
               "Ghost",
               "mounts/primary/Templates/Nope.md"
             )
  end

  test "create_page_from_template: page name with {{date}} placeholder stays literal" do
    File.write!(
      Path.join(ws_path(), "mounts/primary/Templates/Report.md"),
      "# {{title}}\n\nGenerated on {{date}}\n"
    )

    {:ok, %{path: path}} =
      ICM.create_page_from_template(
        "mounts/primary/Clients",
        "Report {{date}}",
        "mounts/primary/Templates/Report.md"
      )

    today = Date.utc_today() |> Date.to_iso8601()
    content = File.read!(Path.join(ws_path(), path))

    # The page name should be preserved verbatim in the title
    assert content =~ "# Report {{date}}"
    # The template's {{date}} placeholder should be substituted with the actual date
    assert content =~ "Generated on #{today}"
    # Verify both are present: the literal {{date}} from page name and substituted date
    assert String.contains?(content, ["# Report {{date}}", "Generated on #{today}"])
  end

  defp ws_path do
    {:ok, %{path: path}} = Manager.current()
    path
  end

  defp workflow_page do
    File.read!(Path.join(ws_path(), "mounts/primary/Workflows/New Inquiry Triage.md"))
  end

  test "rename a referenced page moves the file and rewrites referencing workflows" do
    assert {:ok,
            %{
              path: "mounts/primary/Offers/Founder Package.md",
              updated_workflows: ["New Inquiry Triage"]
            }} =
             ICM.rename("mounts/primary/Offers/Founder Coaching Package.md", "Founder Package")

    refute File.exists?(Path.join(ws_path(), "mounts/primary/Offers/Founder Coaching Package.md"))
    assert File.exists?(Path.join(ws_path(), "mounts/primary/Offers/Founder Package.md"))

    page = workflow_page()
    assert page =~ ~s(path: "Offers/Founder Package.md")
    refute page =~ "Offers/Founder Coaching Package.md"
  end

  test "rename to an invalid or already-existing name" do
    assert {:error, :name_invalid} =
             ICM.rename("mounts/primary/Offers/Founder Coaching Package.md", "a/b")

    assert {:error, :already_exists} =
             ICM.rename("mounts/primary/Offers/Founder Coaching Package.md", "Discovery Call")
  end

  test "renaming a folder containing a referenced page rewrites the workflow" do
    assert {:ok, %{path: "mounts/primary/Offerings", updated_workflows: ["New Inquiry Triage"]}} =
             ICM.rename("mounts/primary/Offers", "Offerings")

    refute File.exists?(Path.join(ws_path(), "mounts/primary/Offers"))

    assert File.exists?(
             Path.join(ws_path(), "mounts/primary/Offerings/Founder Coaching Package.md")
           )

    page = workflow_page()
    assert page =~ ~s(path: "Offerings/Founder Coaching Package.md")
    refute page =~ "Offers/Founder Coaching Package.md"
  end

  test "renaming a folder does not corrupt references to a sibling folder whose name is a prefix superset" do
    {:ok, %{path: "mounts/primary/Offers Extra"}} =
      ICM.create_folder("mounts/primary", "Offers Extra")

    {:ok, %{path: "mounts/primary/Offers Extra/Sidecar.md"}} =
      ICM.create_page("mounts/primary/Offers Extra", "Sidecar")

    workflow_path = Path.join(ws_path(), "mounts/primary/Workflows/New Inquiry Triage.md")

    File.write!(
      workflow_path,
      File.read!(workflow_path) <>
        "\n  - id: sidecar\n    type: icm\n    path: \"Offers Extra/Sidecar.md\"\n"
    )

    assert {:ok, %{path: "mounts/primary/Offerings"}} =
             ICM.rename("mounts/primary/Offers", "Offerings")

    page = workflow_page()
    assert page =~ ~s(path: "Offerings/Founder Coaching Package.md")
    assert page =~ ~s(path: "Offers Extra/Sidecar.md")
    refute page =~ "Offerings Extra/Sidecar.md"
  end

  test "renaming a folder rewrites wildcard workflow references to it" do
    session_prep = fn ->
      File.read!(Path.join(ws_path(), "mounts/primary/Workflows/Session Prep Brief.md"))
    end

    post_session = fn ->
      File.read!(Path.join(ws_path(), "mounts/primary/Workflows/Post-Session Follow-up.md"))
    end

    assert session_prep.() =~ ~s(path: "Clients/*")
    assert post_session.() =~ ~s(path: "Clients/*")

    assert {:ok, %{path: "mounts/primary/Customers", updated_workflows: updated_workflows}} =
             ICM.rename("mounts/primary/Clients", "Customers")

    assert "Session Prep Brief" in updated_workflows
    assert "Post-Session Follow-up" in updated_workflows

    refute File.exists?(Path.join(ws_path(), "mounts/primary/Clients"))
    assert File.exists?(Path.join(ws_path(), "mounts/primary/Customers"))

    assert session_prep.() =~ ~s(path: "Customers/*")
    refute session_prep.() =~ "Clients/*"
    assert post_session.() =~ ~s(path: "Customers/*")
    refute post_session.() =~ "Clients/*"
  end

  test "delete a page removes it and leaves workflows untouched" do
    before_page = workflow_page()

    assert {:ok, %{deleted: true}} = ICM.delete("mounts/primary/Clients/Lea Brunner.md")
    refute File.exists?(Path.join(ws_path(), "mounts/primary/Clients/Lea Brunner.md"))
    assert workflow_page() == before_page
  end

  test "delete a folder recursively removes its contents" do
    assert {:ok, %{deleted: true}} = ICM.delete("mounts/primary/Templates")
    refute File.exists?(Path.join(ws_path(), "mounts/primary/Templates"))
  end

  test "delete a non-existent path returns not_found" do
    assert {:error, :not_found} = ICM.delete("mounts/primary/Offers/Nope.md")
  end

  describe "external mounts (A2-T5b)" do
    defp declare_external!(ws_path, name, ref) do
      config_path = Path.join(ws_path, "config/workspace.yaml")
      {:ok, doc} = YamlElixir.read_from_file(config_path)

      mounts = Map.put(Map.get(doc, "mounts") || %{}, name, %{"kind" => "path", "ref" => ref})

      header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

      entries =
        Enum.flat_map(Enum.sort_by(mounts, &elem(&1, 0)), fn {n, entry} ->
          [
            "  #{n}:"
            | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
                "    #{k}: #{inspect(v)}"
              end)
          ]
        end)

      File.write!(config_path, Enum.join(header ++ ["mounts:"] ++ entries, "\n") <> "\n")
    end

    defp external_icm!(name) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      Manifest.write!(dir, %{id: "ext-id", name: name, description: ""})
      dir
    end

    setup do
      ws = ws_path()
      ext = external_icm!("Ext")
      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/External.md"), "# External Page\n")
      declare_external!(ws, "ext", ext)

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
