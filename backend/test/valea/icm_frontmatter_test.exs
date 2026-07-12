defmodule Valea.ICMFrontmatterTest do
  use ExUnit.Case, async: false

  alias Valea.ICM
  alias Valea.Workspace.Manager

  @page_with_fm """
  ---
  enabled: true
  risk_level: medium
  ---

  # Contract

  Body paragraph.
  """

  @page_broken_yaml "---\n{ broken\n---\n\n# X\n"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    # A fresh scaffold (T8) mints its own real mount from the template's seed
    # content at `mounts/<slug-of-name>` — naming the workspace "Primary"
    # lands it at exactly `mounts/primary`, whose `Workflows/` dir this suite
    # writes its own fixture pages into.
    {:ok, %{path: ws}} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    File.write!(Path.join(ws, "mounts/primary/Workflows/Contract.md"), @page_with_fm)
    File.write!(Path.join(ws, "mounts/primary/Workflows/Broken.md"), @page_broken_yaml)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  describe "split_frontmatter/1" do
    test "splits block including delimiters and trailing newline" do
      {block, body} = ICM.split_frontmatter(@page_with_fm)
      assert block == "---\nenabled: true\nrisk_level: medium\n---\n"
      assert body == "\n# Contract\n\nBody paragraph.\n"
    end

    test "no frontmatter -> empty block, unchanged body" do
      assert {"", "# T\n"} = ICM.split_frontmatter("# T\n")
    end

    test "unterminated frontmatter is treated as body" do
      assert {"", "---\nbroken"} = ICM.split_frontmatter("---\nbroken")
    end
  end

  describe "page/1 + save_page/3 with frontmatter" do
    test "page returns parsed frontmatter, whole-file content, body-only prosemirror" do
      {:ok, page} = ICM.page("mounts/primary/Workflows/Contract.md")
      assert page.frontmatter == %{"enabled" => true, "risk_level" => "medium"}
      assert String.starts_with?(page.content, "---\n")
      refute inspect(page.prosemirror) =~ "enabled: true"
    end

    test "save without edits reattaches frontmatter byte-identically (round trip)" do
      {:ok, page} = ICM.page("mounts/primary/Workflows/Contract.md")

      {:ok, _} =
        ICM.save_page("mounts/primary/Workflows/Contract.md", page.prosemirror, page.hash)

      # canonical body may differ from the fixture's blank-line formatting,
      # but the frontmatter block must be byte-identical and the round trip
      # must be stable: a second open+save writes nothing new.
      {:ok, page2} = ICM.page("mounts/primary/Workflows/Contract.md")
      assert String.starts_with?(page2.content, "---\nenabled: true\nrisk_level: medium\n---\n")

      {:ok, _} =
        ICM.save_page("mounts/primary/Workflows/Contract.md", page2.prosemirror, page2.hash)

      {:ok, page3} = ICM.page("mounts/primary/Workflows/Contract.md")
      assert page3.content == page2.content
    end

    test "malformed yaml -> frontmatter nil, page still readable" do
      {:ok, page} = ICM.page("mounts/primary/Workflows/Broken.md")
      assert page.frontmatter == nil
      assert page.title
    end
  end
end
