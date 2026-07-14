defmodule Valea.ICMFrontmatterTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM

  @page_with_fm """
  ---
  enabled: true
  risk_level: medium
  ---

  # Contract

  Body paragraph.
  """

  @page_broken_yaml "---\n{ broken\n---\n\n# X\n"

  # Post-3.2, `Valea.Mounts.list/1` is config truth over `icms:` only, so a
  # fresh workspace seeds no mount at all — `AgentCase.mount_test_icm!/2`
  # mounts a REAL EXTERNAL ICM carrying just the two fixture pages this
  # suite needs, at `icm.root` (never a `mounts/primary/...`
  # workspace-relative literal).
  setup do
    ws = AgentCase.open_workspace!("Primary")

    icm =
      AgentCase.mount_test_icm!(ws.path,
        pages: %{
          "Workflows/Contract.md" => @page_with_fm,
          "Workflows/Broken.md" => @page_broken_yaml
        }
      )

    %{icm: icm}
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
    test "page returns parsed frontmatter, whole-file content, body-only prosemirror", %{
      icm: icm
    } do
      {:ok, page} = ICM.page(Path.join(icm.root, "Workflows/Contract.md"))
      assert page.frontmatter == %{"enabled" => true, "risk_level" => "medium"}
      assert String.starts_with?(page.content, "---\n")
      refute inspect(page.prosemirror) =~ "enabled: true"
    end

    test "save without edits reattaches frontmatter byte-identically (round trip)", %{icm: icm} do
      contract_path = Path.join(icm.root, "Workflows/Contract.md")
      {:ok, page} = ICM.page(contract_path)

      {:ok, _} = ICM.save_page(contract_path, page.prosemirror, page.hash)

      # canonical body may differ from the fixture's blank-line formatting,
      # but the frontmatter block must be byte-identical and the round trip
      # must be stable: a second open+save writes nothing new.
      {:ok, page2} = ICM.page(contract_path)
      assert String.starts_with?(page2.content, "---\nenabled: true\nrisk_level: medium\n---\n")

      {:ok, _} = ICM.save_page(contract_path, page2.prosemirror, page2.hash)

      {:ok, page3} = ICM.page(contract_path)
      assert page3.content == page2.content
    end

    test "malformed yaml -> frontmatter nil, page still readable", %{icm: icm} do
      {:ok, page} = ICM.page(Path.join(icm.root, "Workflows/Broken.md"))
      assert page.frontmatter == nil
      assert page.title
    end
  end
end
