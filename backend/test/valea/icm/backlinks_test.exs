defmodule Valea.ICM.BacklinksTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM.Backlinks

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` only —
  # a freshly scaffolded workspace carries no seeded mount at all any more
  # (no more legacy embedded `mounts/primary/` glob discovery), so every
  # source/target page in this suite lives inside a REAL EXTERNAL ICM,
  # mounted via `AgentCase.mount_test_icm!/2`. Every path this suite builds
  # (both `target_path` arguments and the expected `source_path` values) is
  # therefore the mounted ICM's ABSOLUTE resolved path — `Path.join(icm.root,
  # "...")` — never the old `"mounts/primary/..."` workspace-relative
  # literal (see `Valea.ICM.Backlinks`'s own moduledoc: `mount.rel_root` is
  # always `nil` now, so `prefix = mount.rel_root || mount.root` is always
  # the absolute root).
  setup do
    ws = AgentCase.open_workspace!()
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{workspace: ws.path, icm: icm}
  end

  test "relative link, angle-bracketed link, and image are confirmed; prose mention is not", %{
    workspace: ws,
    icm: icm
  } do
    target = Path.join(icm.root, "Pricing/Current Pricing.md")

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

    {:ok, links} = Backlinks.backlinks(ws, target)

    assert Enum.map(links, & &1.source_path) ==
             [Path.join(icm.root, "Offers/Ref1.md"), Path.join(icm.root, "Ref2.md")]

    assert Enum.at(links, 0).link_text == "pricing"
  end

  test "absolute destinations resolve too", %{workspace: ws, icm: icm} do
    target = Path.join(icm.root, "Pricing/Current Pricing.md")
    File.write!(Path.join(icm.root, "Ref3.md"), "# Ref3\n\n[p](<#{target}>)\n")
    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.any?(links, &(&1.source_path == Path.join(icm.root, "Ref3.md")))
  end

  test "http and anchor destinations are ignored", %{workspace: ws, icm: icm} do
    File.write!(
      Path.join(icm.root, "Ref4.md"),
      "# Ref4\n\n[x](https://example.com/Current Pricing.md) [y](#current-pricing)\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, Path.join(icm.root, "Pricing/Current Pricing.md"))
    refute Enum.any?(links, &(&1.source_path == Path.join(icm.root, "Ref4.md")))
  end

  test "a code span mentioning the filename is not a backlink", %{workspace: ws, icm: icm} do
    File.write!(
      Path.join(icm.root, "Ref5.md"),
      "# Ref5\n\nRun `Pricing/Current Pricing.md` through the linter.\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, Path.join(icm.root, "Pricing/Current Pricing.md"))
    refute Enum.any?(links, &(&1.source_path == Path.join(icm.root, "Ref5.md")))
  end

  test "a malformed (invalid-UTF-8) page is skipped, not crashed on", %{workspace: ws, icm: icm} do
    File.write!(
      Path.join(icm.root, "Broken.md"),
      <<0xFF, 0xFE, "Current Pricing.md">>
    )

    assert {:ok, links} =
             Backlinks.backlinks(ws, Path.join(icm.root, "Pricing/Current Pricing.md"))

    refute Enum.any?(links, &(&1.source_path == Path.join(icm.root, "Broken.md")))
  end

  test "relative resolution is from the SOURCE page's own directory, not the workspace root", %{
    workspace: ws,
    icm: icm
  } do
    target = Path.join(icm.root, "Pricing/Current Pricing.md")

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

    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.map(links, & &1.source_path) == [Path.join(icm.root, "Offers/Nested/Deep.md")]
  end

  test "a percent-encoded destination (e.g. %20 for a space) is still confirmed", %{
    workspace: ws,
    icm: icm
  } do
    target = Path.join(icm.root, "Pricing/Current Pricing.md")

    File.mkdir_p!(Path.join(icm.root, "Offers"))

    File.write!(
      Path.join(icm.root, "Offers/Encoded.md"),
      "# Encoded\n\n[p](<../Pricing/Current%20Pricing.md>)\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.map(links, & &1.source_path) == [Path.join(icm.root, "Offers/Encoded.md")]
  end

  test "the FIRST matching link text wins when a page links to the target twice", %{
    workspace: ws,
    icm: icm
  } do
    target = Path.join(icm.root, "Target.md")
    File.write!(target, "# Target\n")

    File.write!(
      Path.join(icm.root, "Two Links.md"),
      "First [alpha](<Target.md>) then [beta](<Target.md>).\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, target)
    hit = Enum.find(links, &(&1.source_path == Path.join(icm.root, "Two Links.md")))
    assert hit != nil
    assert hit.link_text == "alpha"
  end
end
