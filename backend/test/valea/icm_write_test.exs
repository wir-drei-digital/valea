defmodule Valea.ICMWriteTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM
  alias Valea.Markdown.ProseMirror

  # See the comment on `seed_mount!/3` in icm_test.exs: the scaffolded
  # `icm/` tree is COPIED (not moved) into `mounts/primary/` so `Valea.ICM`
  # operates on the mount while `Valea.ICM.References` (T4, still hardcoded
  # to `{workspace}/icm/Workflows`) keeps reading the untouched original —
  # the mount-relative paths this module passes to `References` match the
  # `icm/<rel_path>` needles already baked into the seeded Workflows pages,
  # so reference-rewrite behavior is exercised exactly as before.
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
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "W")
    seed_mount!(ws.path, "primary", "Primary")

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

  defp ws_path do
    {:ok, %{path: path}} = Manager.current()
    path
  end

  defp workflow_page do
    File.read!(Path.join(ws_path(), "icm/Workflows/New Inquiry Triage.md"))
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
    assert page =~ "icm/Offers/Founder Package.md"
    refute page =~ "icm/Offers/Founder Coaching Package.md"
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
    assert page =~ "icm/Offerings/Founder Coaching Package.md"
    refute page =~ "icm/Offers/Founder Coaching Package.md"
  end

  test "renaming a folder does not corrupt references to a sibling folder whose name is a prefix superset" do
    {:ok, %{path: "mounts/primary/Offers Extra"}} =
      ICM.create_folder("mounts/primary", "Offers Extra")

    {:ok, %{path: "mounts/primary/Offers Extra/Sidecar.md"}} =
      ICM.create_page("mounts/primary/Offers Extra", "Sidecar")

    workflow_path = Path.join(ws_path(), "icm/Workflows/New Inquiry Triage.md")

    File.write!(
      workflow_path,
      File.read!(workflow_path) <>
        "\n  - id: sidecar\n    type: icm\n    path: icm/Offers Extra/Sidecar.md\n"
    )

    assert {:ok, %{path: "mounts/primary/Offerings"}} =
             ICM.rename("mounts/primary/Offers", "Offerings")

    page = workflow_page()
    assert page =~ "icm/Offerings/Founder Coaching Package.md"
    assert page =~ "icm/Offers Extra/Sidecar.md"
    refute page =~ "icm/Offerings Extra/Sidecar.md"
  end

  test "renaming a folder rewrites wildcard workflow references to it" do
    session_prep = fn ->
      File.read!(Path.join(ws_path(), "icm/Workflows/Session Prep Brief.md"))
    end

    post_session = fn ->
      File.read!(Path.join(ws_path(), "icm/Workflows/Post-Session Follow-up.md"))
    end

    assert session_prep.() =~ "icm/Clients/*"
    assert post_session.() =~ "icm/Clients/*"

    assert {:ok, %{path: "mounts/primary/Customers", updated_workflows: updated_workflows}} =
             ICM.rename("mounts/primary/Clients", "Customers")

    assert "Session Prep Brief" in updated_workflows
    assert "Post-Session Follow-up" in updated_workflows

    refute File.exists?(Path.join(ws_path(), "mounts/primary/Clients"))
    assert File.exists?(Path.join(ws_path(), "mounts/primary/Customers"))

    assert session_prep.() =~ "icm/Customers/*"
    refute session_prep.() =~ "icm/Clients/*"
    assert post_session.() =~ "icm/Customers/*"
    refute post_session.() =~ "icm/Clients/*"
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
end
