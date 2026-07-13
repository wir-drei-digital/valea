defmodule Valea.ICM.LinkRewriteTest do
  use ExUnit.Case, async: false

  alias Valea.ICM
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  # Standard tmp-workspace setup (mirrors `Valea.ICMWriteTest`): a fresh
  # scaffold mints a real "primary" mount from the template's seed content
  # (Pricing/Current Pricing.md, Tone & Voice/Email Tone Guide.md, etc.) —
  # exactly the pages several of these tests rename.
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

  test "rename rewrites only the destination bytes", %{workspace: ws} do
    target = "mounts/primary/Pricing/Current Pricing.md"
    src = "mounts/primary/Offers/Uses Pricing.md"

    body =
      "# Uses\n\nBefore [pricing](<../Pricing/Current Pricing.md>) after.\n\n" <>
        "```\n](../Pricing/Some Other File.md) in a fence stays\n```\n"

    File.write!(Path.join(ws, src), body)

    assert {:ok, %{updated_pages: [^src]}} = ICM.rename(target, "Rates.md")

    after_bytes = File.read!(Path.join(ws, src))

    assert after_bytes ==
             "# Uses\n\nBefore [pricing](<../Pricing/Rates.md>) after.\n\n" <>
               "```\n](../Pricing/Some Other File.md) in a fence stays\n```\n"
  end

  test "unbracketed and image destinations; new name with a space gains brackets", %{
    workspace: ws
  } do
    # The OLD destination itself must be space-free to be valid, parseable
    # (unbracketed) GFM in the first place — CommonMark link destinations
    # without `<>` terminate at the first raw space. "Rates.md" (unlike the
    # seed "Current Pricing.md") satisfies that for the "before" state; the
    # rename target's NEW name is the one that introduces the space.
    File.write!(Path.join(ws, "mounts/primary/Pricing/Rates.md"), "# Rates\n")

    File.write!(
      Path.join(ws, "mounts/primary/A.md"),
      "# A\n\n![x](Pricing/Rates.md)\n"
    )

    assert {:ok, _} = ICM.rename("mounts/primary/Pricing/Rates.md", "Rate Card.md")

    assert File.read!(Path.join(ws, "mounts/primary/A.md")) ==
             "# A\n\n![x](<Pricing/Rate Card.md>)\n"
  end

  test "folder rename rewrites inbound links to children", %{workspace: ws} do
    File.write!(
      Path.join(ws, "mounts/primary/B.md"),
      "# B\n\n[t](<Tone & Voice/Email Tone Guide.md>)\n"
    )

    assert {:ok, _} = ICM.rename("mounts/primary/Tone & Voice", "Voice")

    # The original destination was bracketed on disk — the splice keeps
    # the bracket form it found rather than stripping now-unneeded ones
    # (byte-surgical: only the destination bytes change).
    assert File.read!(Path.join(ws, "mounts/primary/B.md")) ==
             "# B\n\n[t](<Voice/Email Tone Guide.md>)\n"
  end

  test "cross-mount inbound links are rewritten too", %{workspace: ws} do
    assert {:ok, _} = Mounts.create(ws, "second", "second mount")

    File.write!(
      Path.join(ws, "mounts/second/C.md"),
      "# C\n\n[p](<../primary/Pricing/Current Pricing.md>)\n"
    )

    assert {:ok, _} = ICM.rename("mounts/primary/Pricing/Current Pricing.md", "Rates.md")

    assert File.read!(Path.join(ws, "mounts/second/C.md")) ==
             "# C\n\n[p](<../primary/Pricing/Rates.md>)\n"
  end

  test "a fence-only lookalike, with no real link to the renamed target anywhere in the file, is left untouched",
       %{workspace: ws} do
    src = "mounts/primary/D.md"

    body =
      "# D\n\nNo real link here, just a mention.\n\n" <>
        "```\n](../Pricing/Current Pricing.md) looks like a link but is not\n```\n"

    File.write!(Path.join(ws, src), body)

    assert {:ok, %{updated_pages: updated}} =
             ICM.rename("mounts/primary/Pricing/Current Pricing.md", "Rates.md")

    refute src in updated
    assert File.read!(Path.join(ws, src)) == body
  end

  test "known limitation: a fence occurrence sharing a real link's exact destination text is rewritten too",
       %{workspace: ws} do
    # Space-free OLD destination again, for the same unbracketed-GFM reason
    # as the "gains brackets" test above.
    File.write!(Path.join(ws, "mounts/primary/Pricing/Rates.md"), "# Rates\n")

    src = "mounts/primary/E.md"

    body =
      "# E\n\n[real link](Pricing/Rates.md)\n\n" <>
        "```\n](Pricing/Rates.md) lookalike, same file as a real link\n```\n"

    File.write!(Path.join(ws, src), body)

    assert {:ok, %{updated_pages: [^src]}} =
             ICM.rename("mounts/primary/Pricing/Rates.md", "Rate Card.md")

    # The real link's destination changes (and gains brackets, since the
    # new name has a space) — and so, per the documented limitation, does
    # the textually-identical fence occurrence.
    assert File.read!(Path.join(ws, src)) ==
             "# E\n\n[real link](<Pricing/Rate Card.md>)\n\n" <>
               "```\n](<Pricing/Rate Card.md>) lookalike, same file as a real link\n```\n"
  end

  test "a rewrite failure does not roll back the already-completed filesystem rename", %{
    workspace: ws
  } do
    File.write!(Path.join(ws, "mounts/primary/Pricing/Rates.md"), "# Rates\n")

    target_dir = Path.join(ws, "mounts/primary/Pricing")
    mount_dir = Path.join(ws, "mounts/primary")

    File.write!(Path.join(mount_dir, "F.md"), "# F\n\n[p](Pricing/Rates.md)\n")

    # `LinkRewrite`'s atomic write creates an `F.md.tmp` sibling in this
    # directory before renaming it over `F.md` — removing write permission
    # on the directory (not the file) makes that write fail, mirroring
    # `Valea.ICM.ReferencesTest`'s own "rewrite returns error on write
    # failure" fixture. `Pricing/` keeps its own permissions, so the
    # target's own filesystem rename (a rename WITHIN `Pricing/`) still
    # succeeds.
    File.chmod!(mount_dir, 0o555)
    on_exit(fn -> File.chmod!(mount_dir, 0o755) end)

    result = ICM.rename("mounts/primary/Pricing/Rates.md", "Renamed.md")

    assert {:error, {:rewrite_failed, "F.md", _reason}} = result
    refute File.exists?(Path.join(target_dir, "Rates.md"))
    assert File.exists?(Path.join(target_dir, "Renamed.md"))
  end
end
