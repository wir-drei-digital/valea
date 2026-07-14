defmodule Valea.ICM.BacklinksTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM.Backlinks

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` only —
  # a freshly scaffolded workspace carries no seeded mount at all any more
  # (no more legacy embedded `mounts/primary/` glob discovery), so every
  # source/target page in this suite lives inside a REAL EXTERNAL ICM,
  # mounted via `AgentCase.mount_test_icm!/2`. Task 4.2 re-key:
  # `Backlinks.backlinks/2` takes `(mount_key, target_rel_path)` — both
  # `target_rel_path` and every expected `source_path` are ICM-relative
  # (never a `Path.join(icm.root, ...)` absolute literal) — and, per
  # `Backlinks`'s own moduledoc, scans only that ONE mount now (an interim
  # narrowing task 5.6 widens later), so every fixture here lives inside
  # the single mounted ICM.
  setup do
    ws = AgentCase.open_workspace!()
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{workspace: ws.path, icm: icm}
  end

  test "relative link, angle-bracketed link, and image are confirmed; prose mention is not", %{
    icm: icm
  } do
    target = "Pricing/Current Pricing.md"

    File.mkdir_p!(Path.join(icm.root, "Offers"))

    File.write!(
      Path.join(icm.root, "Offers/Ref1.md"),
      "# Ref1\n\nSee [pricing](<../Pricing/Current Pricing.md>).\n"
    )

    # The destination contains a space, so — per the workspace's own on-disk
    # link convention (angle-bracket-wrap when the destination has a space)
    # and plain CommonMark — it must be `<>`-wrapped to parse as a real
    # Image node at all; unwrapped, it stays literal text and would never
    # reach a Link/Image AST node in the first place.
    File.write!(
      Path.join(icm.root, "Ref2.md"),
      "# Ref2\n\n![shot](<Pricing/Current Pricing.md>)\n"
    )

    File.write!(
      Path.join(icm.root, "NotALink.md"),
      "# NotALink\n\nThe file Pricing/Current Pricing.md is mentioned in prose only.\n"
    )

    {:ok, links} = Backlinks.backlinks(icm.mount_key, target)

    assert Enum.map(links, & &1.source_path) == ["Offers/Ref1.md", "Ref2.md"]

    assert Enum.at(links, 0).link_text == "pricing"
  end

  test "absolute destinations resolve too", %{icm: icm} do
    target = "Pricing/Current Pricing.md"
    target_abs = Path.join(icm.root, target)
    File.write!(Path.join(icm.root, "Ref3.md"), "# Ref3\n\n[p](<#{target_abs}>)\n")
    {:ok, links} = Backlinks.backlinks(icm.mount_key, target)
    assert Enum.any?(links, &(&1.source_path == "Ref3.md"))
  end

  test "http and anchor destinations are ignored", %{icm: icm} do
    File.write!(
      Path.join(icm.root, "Ref4.md"),
      "# Ref4\n\n[x](https://example.com/Current Pricing.md) [y](#current-pricing)\n"
    )

    {:ok, links} = Backlinks.backlinks(icm.mount_key, "Pricing/Current Pricing.md")
    refute Enum.any?(links, &(&1.source_path == "Ref4.md"))
  end

  test "a code span mentioning the filename is not a backlink", %{icm: icm} do
    File.write!(
      Path.join(icm.root, "Ref5.md"),
      "# Ref5\n\nRun `Pricing/Current Pricing.md` through the linter.\n"
    )

    {:ok, links} = Backlinks.backlinks(icm.mount_key, "Pricing/Current Pricing.md")
    refute Enum.any?(links, &(&1.source_path == "Ref5.md"))
  end

  test "a malformed (invalid-UTF-8) page is skipped, not crashed on", %{icm: icm} do
    File.write!(
      Path.join(icm.root, "Broken.md"),
      <<0xFF, 0xFE, "Current Pricing.md">>
    )

    assert {:ok, links} = Backlinks.backlinks(icm.mount_key, "Pricing/Current Pricing.md")

    refute Enum.any?(links, &(&1.source_path == "Broken.md"))
  end

  test "relative resolution is from the SOURCE page's own directory, not the mount root", %{
    icm: icm
  } do
    target = "Pricing/Current Pricing.md"

    # A same-named "Current Pricing.md" living directly under Offers/ — a
    # link written relative to *that* directory must resolve to Offers'
    # own copy, not accidentally to the real target merely because the
    # basename matches (the substring pre-filter would still hit both).
    File.mkdir_p!(Path.join(icm.root, "Offers"))
    File.write!(Path.join(icm.root, "Offers/Current Pricing.md"), "# Decoy\n")

    nested_dir = Path.join(icm.root, "Offers/Nested")
    File.mkdir_p!(nested_dir)

    File.write!(
      Path.join(nested_dir, "Deep.md"),
      "# Deep\n\n[p](<../../Pricing/Current Pricing.md>)\n"
    )

    {:ok, links} = Backlinks.backlinks(icm.mount_key, target)
    assert Enum.map(links, & &1.source_path) == ["Offers/Nested/Deep.md"]
  end

  test "a percent-encoded destination (e.g. %20 for a space) is still confirmed", %{
    icm: icm
  } do
    target = "Pricing/Current Pricing.md"

    File.mkdir_p!(Path.join(icm.root, "Offers"))

    File.write!(
      Path.join(icm.root, "Offers/Encoded.md"),
      "# Encoded\n\n[p](<../Pricing/Current%20Pricing.md>)\n"
    )

    {:ok, links} = Backlinks.backlinks(icm.mount_key, target)
    assert Enum.map(links, & &1.source_path) == ["Offers/Encoded.md"]
  end

  test "the FIRST matching link text wins when a page links to the target twice", %{
    icm: icm
  } do
    target = "Target.md"
    File.write!(Path.join(icm.root, target), "# Target\n")

    File.write!(
      Path.join(icm.root, "Two Links.md"),
      "First [alpha](<Target.md>) then [beta](<Target.md>).\n"
    )

    {:ok, links} = Backlinks.backlinks(icm.mount_key, target)
    hit = Enum.find(links, &(&1.source_path == "Two Links.md"))
    assert hit != nil
    assert hit.link_text == "alpha"
  end

  test "an unknown/disabled mount key returns :outside_workspace" do
    assert {:error, :outside_workspace} = Backlinks.backlinks("does-not-exist", "Target.md")
  end

  describe "interim single-ICM scope narrowing (task 4.2)" do
    test "a link living in a DIFFERENT mount pointing at this one's page is NOT discovered", %{
      workspace: ws,
      icm: icm
    } do
      other = AgentCase.mount_test_icm!(ws, name: "Other")
      target_abs = Path.join(icm.root, "Pricing/Current Pricing.md")

      File.write!(Path.join(other.root, "FromOther.md"), "# From Other\n\n[p](<#{target_abs}>)\n")

      {:ok, links} = Backlinks.backlinks(icm.mount_key, "Pricing/Current Pricing.md")
      refute Enum.any?(links, &(&1.source_path == "FromOther.md"))
    end
  end
end
