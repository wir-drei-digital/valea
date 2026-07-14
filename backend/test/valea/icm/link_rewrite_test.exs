defmodule Valea.ICM.LinkRewriteTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM
  alias Valea.ICM.Backlinks

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY —
  # every mount is external (by-reference), so `setup` mounts a REAL
  # external ICM (`AgentCase.mount_test_icm!/2`) seeded with the pages this
  # suite renames (`Pricing/Current Pricing.md`, `Tone & Voice/Email Tone
  # Guide.md`), instead of relying on the legacy scaffold's embedded
  # `mounts/primary/` starter mount, which `Mounts.list/1` can no longer
  # see. Every path a test needs is built against `icm.root` (the mounted
  # ICM's REALPATH-resolved absolute root), never a hand-written
  # `"mounts/primary/..."` literal.
  setup do
    ws = AgentCase.open_workspace!("Primary")

    icm =
      AgentCase.mount_test_icm!(ws.path,
        name: "Primary",
        pages: %{
          "Pricing/Current Pricing.md" => "# Current Pricing\n",
          "Tone & Voice/Email Tone Guide.md" => "# Email Tone Guide\n"
        }
      )

    %{workspace: ws.path, icm: icm}
  end

  test "rename rewrites only the destination bytes", %{icm: icm} do
    target = Path.join(icm.root, "Pricing/Current Pricing.md")
    src = Path.join(icm.root, "Offers/Uses Pricing.md")

    body =
      "# Uses\n\nBefore [pricing](<../Pricing/Current Pricing.md>) after.\n\n" <>
        "```\n](../Pricing/Some Other File.md) in a fence stays\n```\n"

    File.mkdir_p!(Path.dirname(src))
    File.write!(src, body)

    assert {:ok, %{updated_pages: [^src]}} = ICM.rename(target, "Rates.md")

    after_bytes = File.read!(src)

    assert after_bytes ==
             "# Uses\n\nBefore [pricing](<../Pricing/Rates.md>) after.\n\n" <>
               "```\n](../Pricing/Some Other File.md) in a fence stays\n```\n"
  end

  test "unbracketed and image destinations; new name with a space gains brackets", %{
    icm: icm
  } do
    # The OLD destination itself must be space-free to be valid, parseable
    # (unbracketed) GFM in the first place — CommonMark link destinations
    # without `<>` terminate at the first raw space. "Rates.md" (unlike the
    # seed "Current Pricing.md") satisfies that for the "before" state; the
    # rename target's NEW name is the one that introduces the space.
    File.write!(Path.join(icm.root, "Pricing/Rates.md"), "# Rates\n")

    File.write!(
      Path.join(icm.root, "A.md"),
      "# A\n\n![x](Pricing/Rates.md)\n"
    )

    assert {:ok, _} = ICM.rename(Path.join(icm.root, "Pricing/Rates.md"), "Rate Card.md")

    assert File.read!(Path.join(icm.root, "A.md")) ==
             "# A\n\n![x](<Pricing/Rate Card.md>)\n"
  end

  test "folder rename rewrites inbound links to children", %{icm: icm} do
    File.write!(
      Path.join(icm.root, "B.md"),
      "# B\n\n[t](<Tone & Voice/Email Tone Guide.md>)\n"
    )

    assert {:ok, _} = ICM.rename(Path.join(icm.root, "Tone & Voice"), "Voice")

    # The original destination was bracketed on disk — the splice keeps
    # the bracket form it found rather than stripping now-unneeded ones
    # (byte-surgical: only the destination bytes change).
    assert File.read!(Path.join(icm.root, "B.md")) ==
             "# B\n\n[t](<Voice/Email Tone Guide.md>)\n"
  end

  test "cross-mount inbound links are rewritten too", %{workspace: ws, icm: icm} do
    second = AgentCase.mount_test_icm!(ws, name: "Second")

    target_abs = Path.join(icm.root, "Pricing/Current Pricing.md")
    c_path = Path.join(second.root, "C.md")

    File.write!(c_path, "# C\n\n[p](<#{target_abs}>)\n")

    assert {:ok, _} = ICM.rename(target_abs, "Rates.md")

    new_abs = Path.join(icm.root, "Pricing/Rates.md")

    assert File.read!(c_path) == "# C\n\n[p](<#{new_abs}>)\n"
  end

  test "a fence-only lookalike, with no real link to the renamed target anywhere in the file, is left untouched",
       %{icm: icm} do
    src = Path.join(icm.root, "D.md")

    body =
      "# D\n\nNo real link here, just a mention.\n\n" <>
        "```\n](../Pricing/Current Pricing.md) looks like a link but is not\n```\n"

    File.write!(src, body)

    assert {:ok, %{updated_pages: updated}} =
             ICM.rename(Path.join(icm.root, "Pricing/Current Pricing.md"), "Rates.md")

    refute src in updated
    assert File.read!(src) == body
  end

  test "known limitation: a fence occurrence sharing a real link's exact destination text is rewritten too",
       %{icm: icm} do
    # Space-free OLD destination again, for the same unbracketed-GFM reason
    # as the "gains brackets" test above.
    File.write!(Path.join(icm.root, "Pricing/Rates.md"), "# Rates\n")

    src = Path.join(icm.root, "E.md")

    body =
      "# E\n\n[real link](Pricing/Rates.md)\n\n" <>
        "```\n](Pricing/Rates.md) lookalike, same file as a real link\n```\n"

    File.write!(src, body)

    assert {:ok, %{updated_pages: [^src]}} =
             ICM.rename(Path.join(icm.root, "Pricing/Rates.md"), "Rate Card.md")

    # The real link's destination changes (and gains brackets, since the
    # new name has a space) — and so, per the documented limitation, does
    # the textually-identical fence occurrence.
    assert File.read!(src) ==
             "# E\n\n[real link](<Pricing/Rate Card.md>)\n\n" <>
               "```\n](<Pricing/Rate Card.md>) lookalike, same file as a real link\n```\n"
  end

  test "known limitation: a confirmed link written in HTML-entity form is left dangling, not corrupted",
       %{icm: icm, workspace: ws} do
    # MDEx entity-decodes `&amp;` -> `&` while parsing, so `Backlinks.destinations/3`
    # reports this link's `:url` as "Foo&Bar.md" — NOT the raw on-disk bytes
    # ("Foo&amp;Bar.md"). Confirm the premise first: on the installed MDEx,
    # this really is a genuine confirmed inbound reference to the target
    # (not a non-match), so the skip asserted below is a real documented
    # gap, not a vacuous case.
    target_abs = Path.join(icm.root, "Foo&Bar.md")
    File.write!(target_abs, "# Foo&Bar\n")

    src = Path.join(icm.root, "G.md")
    body = "# G\n\nSee [x](Foo&amp;Bar.md) here.\n"
    File.write!(src, body)

    assert [%{url: "Foo&Bar.md", abs: ^target_abs}] = Backlinks.destinations(ws, src, body)

    assert {:ok, %{updated_pages: updated}} = ICM.rename(target_abs, "Renamed.md")

    refute src in updated
    assert File.read!(src) == body
  end

  test "a rewrite failure does not roll back the already-completed filesystem rename", %{
    icm: icm
  } do
    File.write!(Path.join(icm.root, "Pricing/Rates.md"), "# Rates\n")

    target_dir = Path.join(icm.root, "Pricing")
    mount_dir = icm.root

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

    result = ICM.rename(Path.join(icm.root, "Pricing/Rates.md"), "Renamed.md")

    assert {:error, {:rewrite_failed, "F.md", _reason}} = result
    refute File.exists?(Path.join(target_dir, "Rates.md"))
    assert File.exists?(Path.join(target_dir, "Renamed.md"))
  end
end
