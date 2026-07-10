defmodule Valea.ICMWriteTest do
  use ExUnit.Case, async: false

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
    {:ok, _} = Manager.create(Path.join(dir, "workspaces"), "W")

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
    page = load("Offers/Founder Coaching Package.md")
    assert page.hash =~ ~r/^[0-9a-f]{64}$/
    assert %{"type" => "doc"} = page.prosemirror
  end

  test "save_page round-trips an edit and returns a new hash" do
    page = load("Policies/No Medical Advice.md")
    {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
    {:ok, %{hash: new_hash}} = ICM.save_page(page.path, pm, page.hash)
    refute new_hash == page.hash
    assert load(page.path).content =~ "One more line."
  end

  test "save_page rejects a stale base hash" do
    page = load("Policies/No Medical Advice.md")
    {:ok, pm} = ProseMirror.from_markdown("# Changed\n")
    {:ok, _} = ICM.save_page(page.path, pm, page.hash)
    assert {:error, :page_changed} = ICM.save_page(page.path, pm, page.hash)
  end

  test "save_page enforces containment and existence" do
    {:ok, pm} = ProseMirror.from_markdown("# X\n")

    assert {:error, :outside_workspace} =
             ICM.save_page("../logs/audit.jsonl", pm, String.duplicate("0", 64))

    assert {:error, :not_found} = ICM.save_page("Offers/Nope.md", pm, String.duplicate("0", 64))
  end

  test "unchanged save is byte-identical (determinism through the write path)" do
    page = load("Offers/Founder Coaching Package.md")
    {:ok, %{hash: h2}} = ICM.save_page(page.path, page.prosemirror, page.hash)
    assert h2 == page.hash
  end

  test "create_page seeds title and appends .md" do
    {:ok, %{path: path}} = ICM.create_page("Decisions", "Pricing Call")
    assert path == "Decisions/Pricing Call.md"
    assert load(path).content == "# Pricing Call\n"
  end

  test "create_page at root, create_folder, duplicate and invalid names" do
    {:ok, %{path: "Scratch.md"}} = ICM.create_page("", "Scratch")
    {:ok, %{path: "Projects"}} = ICM.create_folder("", "Projects")
    assert {:error, :already_exists} = ICM.create_folder("", "Projects")
    assert {:error, :already_exists} = ICM.create_page("", "Scratch")

    for bad <- ["", "  ", "a/b", "a\\b", ".hidden"] do
      assert {:error, :name_invalid} = ICM.create_page("", bad)
      assert {:error, :name_invalid} = ICM.create_folder("", bad)
    end

    assert {:error, :outside_workspace} = ICM.create_page("..", "x")
  end

  test "create_page normalizes unicode and trims whitespace into the written path" do
    {:ok, %{path: path}} = ICM.create_page("", " Café ")
    assert path == "Café.md"
    assert path == String.normalize(path, :nfc)
    assert load(path).title == "Café"
  end

  test "create under a file parent returns name_invalid, and x. gets a single extension" do
    assert {:error, :name_invalid} =
             ICM.create_page("Offers/Founder Coaching Package.md", "Child")

    {:ok, %{path: "Trailing.md"}} = ICM.create_page("", "Trailing.")
  end

  defp ws_path do
    {:ok, %{path: path}} = Manager.current()
    path
  end

  defp workflow_yaml do
    File.read!(Path.join(ws_path(), "workflows/new_inquiry_triage.yaml"))
  end

  test "rename a referenced page moves the file and rewrites referencing workflows" do
    assert {:ok, %{path: "Offers/Founder Package.md", updated_workflows: ["New Inquiry Triage"]}} =
             ICM.rename("Offers/Founder Coaching Package.md", "Founder Package")

    refute File.exists?(Path.join(ws_path(), "icm/Offers/Founder Coaching Package.md"))
    assert File.exists?(Path.join(ws_path(), "icm/Offers/Founder Package.md"))

    yaml = workflow_yaml()
    assert yaml =~ "icm/Offers/Founder Package.md"
    refute yaml =~ "icm/Offers/Founder Coaching Package.md"
  end

  test "rename to an invalid or already-existing name" do
    assert {:error, :name_invalid} =
             ICM.rename("Offers/Founder Coaching Package.md", "a/b")

    assert {:error, :already_exists} =
             ICM.rename("Offers/Founder Coaching Package.md", "Discovery Call")
  end

  test "renaming a folder containing a referenced page rewrites the workflow" do
    assert {:ok, %{path: "Offerings", updated_workflows: ["New Inquiry Triage"]}} =
             ICM.rename("Offers", "Offerings")

    refute File.exists?(Path.join(ws_path(), "icm/Offers"))
    assert File.exists?(Path.join(ws_path(), "icm/Offerings/Founder Coaching Package.md"))

    yaml = workflow_yaml()
    assert yaml =~ "icm/Offerings/Founder Coaching Package.md"
    refute yaml =~ "icm/Offers/Founder Coaching Package.md"
  end

  test "renaming a folder does not corrupt references to a sibling folder whose name is a prefix superset" do
    {:ok, %{path: "Offers Extra"}} = ICM.create_folder("", "Offers Extra")
    {:ok, %{path: "Offers Extra/Sidecar.md"}} = ICM.create_page("Offers Extra", "Sidecar")

    workflow_path = Path.join(ws_path(), "workflows/new_inquiry_triage.yaml")

    File.write!(
      workflow_path,
      File.read!(workflow_path) <>
        "  - id: sidecar\n    type: icm\n    path: icm/Offers Extra/Sidecar.md\n"
    )

    assert {:ok, %{path: "Offerings"}} = ICM.rename("Offers", "Offerings")

    yaml = workflow_yaml()
    assert yaml =~ "icm/Offerings/Founder Coaching Package.md"
    assert yaml =~ "icm/Offers Extra/Sidecar.md"
    refute yaml =~ "icm/Offerings Extra/Sidecar.md"
  end

  test "delete a page removes it and leaves workflows untouched" do
    before_yaml = workflow_yaml()

    assert {:ok, %{deleted: true}} = ICM.delete("Clients/Lea Brunner.md")
    refute File.exists?(Path.join(ws_path(), "icm/Clients/Lea Brunner.md"))
    assert workflow_yaml() == before_yaml
  end

  test "delete a folder recursively removes its contents" do
    assert {:ok, %{deleted: true}} = ICM.delete("Templates")
    refute File.exists?(Path.join(ws_path(), "icm/Templates"))
  end

  test "delete a non-existent path returns not_found" do
    assert {:error, :not_found} = ICM.delete("Offers/Nope.md")
  end
end
