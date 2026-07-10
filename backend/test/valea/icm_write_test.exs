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
end
