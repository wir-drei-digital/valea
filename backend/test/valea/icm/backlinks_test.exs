defmodule Valea.ICM.BacklinksTest do
  use ExUnit.Case, async: false

  alias Valea.ICM.Backlinks
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path}
  end

  test "relative link, angle-bracketed link, and image are confirmed; prose mention is not", %{
    workspace: ws
  } do
    target = "mounts/primary/Pricing/Current Pricing.md"

    File.write!(
      Path.join(ws, "mounts/primary/Offers/Ref1.md"),
      "# Ref1\n\nSee [pricing](<../Pricing/Current Pricing.md>).\n"
    )

    # The destination contains a space, so — per the workspace's own on-disk
    # link convention (angle-bracket-wrap when the destination has a space)
    # and plain CommonMark — it must be `<>`-wrapped to parse as a real
    # Image node at all; unwrapped, it stays literal text and would never
    # reach a Link/Image AST node in the first place.
    File.write!(
      Path.join(ws, "mounts/primary/Ref2.md"),
      "# Ref2\n\n![shot](<Pricing/Current Pricing.md>)\n"
    )

    File.write!(
      Path.join(ws, "mounts/primary/NotALink.md"),
      "# NotALink\n\nThe file Pricing/Current Pricing.md is mentioned in prose only.\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, target)

    assert Enum.map(links, & &1.source_path) ==
             ["mounts/primary/Offers/Ref1.md", "mounts/primary/Ref2.md"]

    assert Enum.at(links, 0).link_text == "pricing"
  end

  test "absolute destinations resolve too", %{workspace: ws} do
    target = "mounts/primary/Pricing/Current Pricing.md"
    abs = Path.join(ws, target)
    File.write!(Path.join(ws, "mounts/primary/Ref3.md"), "# Ref3\n\n[p](<#{abs}>)\n")
    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.any?(links, &(&1.source_path == "mounts/primary/Ref3.md"))
  end

  test "http and anchor destinations are ignored", %{workspace: ws} do
    File.write!(
      Path.join(ws, "mounts/primary/Ref4.md"),
      "# Ref4\n\n[x](https://example.com/Current Pricing.md) [y](#current-pricing)\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, "mounts/primary/Pricing/Current Pricing.md")
    refute Enum.any?(links, &(&1.source_path == "mounts/primary/Ref4.md"))
  end

  test "a code span mentioning the filename is not a backlink", %{workspace: ws} do
    File.write!(
      Path.join(ws, "mounts/primary/Ref5.md"),
      "# Ref5\n\nRun `Pricing/Current Pricing.md` through the linter.\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, "mounts/primary/Pricing/Current Pricing.md")
    refute Enum.any?(links, &(&1.source_path == "mounts/primary/Ref5.md"))
  end

  test "a malformed (invalid-UTF-8) page is skipped, not crashed on", %{workspace: ws} do
    File.write!(
      Path.join(ws, "mounts/primary/Broken.md"),
      <<0xFF, 0xFE, "Current Pricing.md">>
    )

    assert {:ok, links} = Backlinks.backlinks(ws, "mounts/primary/Pricing/Current Pricing.md")
    refute Enum.any?(links, &(&1.source_path == "mounts/primary/Broken.md"))
  end

  test "relative resolution is from the SOURCE page's own directory, not the workspace root", %{
    workspace: ws
  } do
    target = "mounts/primary/Pricing/Current Pricing.md"

    # A same-named "Current Pricing.md" living directly under Offers/ — a
    # link written relative to *that* directory must resolve to Offers'
    # own copy, not accidentally to the real target merely because the
    # basename matches (the substring pre-filter would still hit both).
    File.write!(Path.join(ws, "mounts/primary/Offers/Current Pricing.md"), "# Decoy\n")

    nested_dir = Path.join(ws, "mounts/primary/Offers/Nested")
    File.mkdir_p!(nested_dir)

    File.write!(
      Path.join(nested_dir, "Deep.md"),
      "# Deep\n\n[p](<../../Pricing/Current Pricing.md>)\n"
    )

    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.map(links, & &1.source_path) == ["mounts/primary/Offers/Nested/Deep.md"]
  end
end
