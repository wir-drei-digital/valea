defmodule Valea.ICMTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM

  defp external_icm!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})
    dir
  end

  # Post-3.2, `Valea.Mounts.list/1` is config truth over `icms:` only — a
  # fresh workspace seeds no mount at all (`Manager.create/2` still
  # physically scaffolds a legacy `mounts/<slug>` starter folder, but never
  # registers it under `icms:`, so `Mounts.list/1` can't see it). This whole
  # suite's fixtures assume the legacy scaffold's rich seed content (Offers/,
  # Policies/, Pricing/, Templates/, Clients/, Tone & Voice/, Workflows/,
  # Decisions/), so it's copied fresh into an EXTERNAL tmp dir and mounted
  # via `Mounts.mount/2`, landing at mount key "primary" (name "Primary"
  # slugifies to "primary" — `Valea.Workspace.Scaffold.slugify/1`), exactly
  # the vocabulary every assertion below addresses (via `icm.root`, never a
  # `mounts/primary/...` workspace-relative literal).
  defp mount_starter_icm!(workspace, name \\ "Primary") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-starter-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(
      Path.join(:code.priv_dir(:valea), "legacy_workspace_template/mounts/starter"),
      dir
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})

    {:ok, %{mount_key: mount_key, id: id}} = Mounts.mount(workspace, dir)
    %{mount_key: mount_key, id: id, root: Mounts.mount_by_key(workspace, mount_key).root}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")
    icm = mount_starter_icm!(ws.path)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path, icm: icm}
  end

  test "tree lists seeded folders with counts, grouped by mount", %{icm: icm} do
    {:ok, [mount]} = ICM.tree()
    assert mount.mount == "primary"
    assert mount.title == "Primary"
    assert mount.root_rel == icm.root

    names = Enum.map(mount.tree, & &1.name)
    assert "Offers" in names
    assert "Tone & Voice" in names
    offers = Enum.find(mount.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == Path.join(icm.root, "Offers")
    assert offers.page_count == 2
    child = Enum.find(offers.children, &(&1.name == "Founder Coaching Package"))
    assert child
    assert child.path == Path.join(icm.root, "Offers/Founder Coaching Package.md")
    assert child.uri == "icm://" <> Path.join(icm.root, "Offers/Founder Coaching Package.md")
  end

  test "tree lists non-.md files as :file leaves with a lowercase ext, still excluding hidden files",
       %{icm: icm} do
    dir = Path.join(icm.root, "Offers")
    File.write!(Path.join(dir, "X.pdf"), "%PDF-1.4 fake")
    File.write!(Path.join(dir, "logo.PNG"), "not really a png")
    File.write!(Path.join(dir, ".hidden.pdf"), "still hidden")

    {:ok, [mount]} = ICM.tree()
    offers = Enum.find(mount.tree, &(&1.name == "Offers"))

    pdf = Enum.find(offers.children, &(&1.name == "X.pdf"))

    assert pdf == %{
             name: "X.pdf",
             path: Path.join(icm.root, "Offers/X.pdf"),
             type: :file,
             ext: ".pdf"
           }

    png = Enum.find(offers.children, &(&1.name == "logo.PNG"))

    assert png == %{
             name: "logo.PNG",
             path: Path.join(icm.root, "Offers/logo.PNG"),
             type: :file,
             ext: ".png"
           }

    refute Enum.any?(offers.children, &String.starts_with?(&1.name, "."))

    # file leaves never count as pages
    assert offers.page_count == 2

    # the mount's own manifest is infrastructure, not knowledge content —
    # never listed at the mount root
    refute Enum.any?(mount.tree, &(&1.name == "icm.yaml"))
  end

  test "external mounts are surfaced in tree/0 with the absolute physical root/paths (A2-T5b), alongside the primary group",
       %{ws: ws, icm: icm} do
    ext = external_icm!("Ext")
    File.mkdir_p!(Path.join(ext, "Offers"))
    File.write!(Path.join(ext, "Offers/X.md"), "# X\n")
    {:ok, _} = Mounts.mount(ws, ext)

    # Derive assertions from the EFFECTIVE mount's realpath-resolved root
    # (m.root), not the raw tmp path — on macOS the raw `/var/folders/...`
    # tmp path never string-matches the resolved `/private/var/...` root.
    [ext_mount] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))

    assert {:ok, groups} = ICM.tree()
    assert Enum.map(groups, & &1.mount) |> Enum.sort() == ["ext", "primary"]

    ext_group = Enum.find(groups, &(&1.mount == "ext"))
    assert ext_group.title == "Ext"
    # root_rel stays a string (the RPC type holds), but its value is the
    # ABSOLUTE physical root — the one vocabulary this group's node paths
    # use (binding semantic 1). Every mount is external now (task 3.2), so
    # this is true of BOTH groups.
    assert ext_group.root_rel == ext_mount.root

    offers = Enum.find(ext_group.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == Path.join(ext_mount.root, "Offers")
    assert offers.page_count == 1

    x = Enum.find(offers.children, &(&1.name == "X"))
    assert x.type == :page
    assert x.path == Path.join(ext_mount.root, "Offers/X.md")
    assert x.uri == "icm://" <> Path.join(ext_mount.root, "Offers/X.md")

    # The workspace's own "primary" group is external too — same absolute
    # vocabulary.
    primary = Enum.find(groups, &(&1.mount == "primary"))
    assert primary.root_rel == icm.root
  end

  test "a DISABLED external mount drops out of tree/0 entirely", %{ws: ws} do
    ext = external_icm!("Ext")
    {:ok, _} = Mounts.mount(ws, ext)
    :ok = Mounts.set_enabled(ws, "ext", false)

    assert {:ok, groups} = ICM.tree()
    assert Enum.map(groups, & &1.mount) == ["primary"]
  end

  test "page reads content with title and uri", %{icm: icm} do
    path = Path.join(icm.root, "Offers/Founder Coaching Package.md")
    {:ok, page} = ICM.page(path)
    assert page.title == "Founder Coaching Package"
    assert page.uri == "icm://" <> path
    assert page.content =~ "## Best fit"
  end

  test "page rejects escape attempts", %{icm: icm} do
    assert {:error, :outside_workspace} = ICM.page("../logs/audit.jsonl")
    assert {:error, :outside_workspace} = ICM.page("Offers/../../secrets/x")
    assert {:error, :outside_workspace} = ICM.page(Path.join(icm.root, "../../logs/audit.jsonl"))
  end

  test "page returns not_found for a missing page", %{icm: icm} do
    assert {:error, :not_found} = ICM.page(Path.join(icm.root, "Offers/Nope.md"))
  end

  test "errors without a workspace", %{icm: icm} do
    path = Path.join(icm.root, "Offers/Founder Coaching Package.md")
    Manager.close()
    assert {:error, :no_workspace} = ICM.tree()
    assert {:error, :no_workspace} = ICM.page(path)
  end

  describe "multiple mounts" do
    setup %{ws: ws} do
      # Named "A"/"B" (not "Mount A"/"Mount B") so the auto-derived mount
      # key (`Valea.Workspace.Scaffold.slugify/1` of the manifest name)
      # lands at exactly "a"/"b" — the literal keys every assertion below
      # addresses.
      a = external_icm!("A")
      File.write!(Path.join(a, "Notes.md"), "# A Note\n")
      {:ok, %{mount_key: "a"}} = Mounts.mount(ws, a)

      b = external_icm!("B")
      File.write!(Path.join(b, "Secret.md"), "# B Secret\n")
      {:ok, %{mount_key: "b"}} = Mounts.mount(ws, b)
      :ok = Mounts.set_enabled(ws, "b", false)

      %{a_root: Mounts.mount_by_key(ws, "a").root, b_root: Mounts.mount_by_key(ws, "b").root}
    end

    test "tree/0 returns one entry per ENABLED mount, with each mount's own node-path vocabulary",
         %{a_root: a_root} do
      {:ok, mounts} = ICM.tree()
      assert Enum.map(mounts, & &1.mount) |> Enum.sort() == ["a", "primary"]
      refute Enum.any?(mounts, &(&1.mount == "b"))

      a = Enum.find(mounts, &(&1.mount == "a"))
      assert a.title == "A"
      assert a.root_rel == a_root
      notes_path = Path.join(a_root, "Notes.md")
      assert [%{path: ^notes_path, type: :page, uri: uri}] = a.tree
      assert uri == "icm://" <> notes_path
    end

    test "page reads a specific mount's file by its full absolute path", %{a_root: a_root} do
      notes_path = Path.join(a_root, "Notes.md")
      assert {:ok, page} = ICM.page(notes_path)
      assert page.content == "# A Note\n"
      assert page.uri == "icm://" <> notes_path
    end

    # Was "page reads a DISABLED mount's page fine — enabled-gating is a
    # read_roots/agent concern, not the editor's" under the old EMBEDDED
    # mount model, where `Mounts.mount_for/1` attributed a
    # `mounts/<name>/...` path by lexical prefix alone, regardless of
    # `enabled`. Every mount is external (by-reference) now, and
    # `Mounts.mount_for/2`'s own moduledoc attributes ONLY among
    # ENABLED, non-degraded mounts — confirmed by the sibling "a DISABLED
    # external mount's absolute paths still get :outside_workspace from
    # every editor op" test below (A2-T5b): disabling a by-reference mount
    # revokes trust in that outside-the-workspace location entirely, so
    # the editor stops touching it too, not just the agent/read_roots
    # surface. (`Valea.ICM`'s own moduledoc "DECISION" section still
    # describes the old embedded-only stance verbatim — stale prose, not
    # a behavior this suite can restore without breaking that sibling
    # test.)
    test "page on a DISABLED mount's absolute path is outside_workspace — disabling a by-reference mount revokes editor access too",
         %{b_root: b_root} do
      assert {:error, :outside_workspace} = ICM.page(Path.join(b_root, "Secret.md"))
    end

    test "a `..` escape cannot cross from one mount into another", %{
      a_root: a_root,
      b_root: b_root
    } do
      escape_path = Path.join([a_root, "..", Path.basename(b_root), "Secret.md"])
      assert {:error, :outside_workspace} = ICM.page(escape_path)
    end

    test "create/rename/delete operate within the resolving mount's own containment", %{
      a_root: a_root,
      b_root: b_root
    } do
      assert {:ok, %{path: new_page_path}} = ICM.create_page(a_root, "New")
      assert new_page_path == Path.join(a_root, "New.md")

      assert {:ok, %{path: sub_path}} = ICM.create_folder(a_root, "Sub")
      assert sub_path == Path.join(a_root, "Sub")

      assert {:ok, %{path: renamed_path}} = ICM.rename(new_page_path, "Renamed")
      assert renamed_path == Path.join(a_root, "Renamed.md")

      assert {:ok, %{deleted: true}} = ICM.delete(renamed_path)
      refute File.exists?(renamed_path)

      # Escaping mount a's own root while creating is denied, even though
      # mount "b" is a real, discovered mount.
      escape_parent = Path.join([a_root, "..", Path.basename(b_root)])
      assert {:error, :outside_workspace} = ICM.create_page(escape_parent, "Intruder")
    end
  end

  describe "external mounts" do
    setup %{ws: ws} do
      ext = external_icm!("Ext")
      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/External.md"), "# External Page\n")
      {:ok, _} = Mounts.mount(ws, ext)

      %{ws: ws, ext: ext}
    end

    test "external mounts are editable via ICM ops through their absolute physical paths (A2-T5b)",
         %{ws: ws} do
      # Sanity: the external mount IS effective.
      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))
      assert m.rel_root == nil

      # Derive the page path from the EFFECTIVE mount's realpath-RESOLVED root
      # (`m.root`), not the raw tmp path — on macOS the raw `/var/folders/...`
      # tmp path never string-matches the resolved `/private/var/...` root.
      ext_page_abs = Path.join(m.root, "Offers/External.md")
      assert File.exists?(ext_page_abs)
      assert {:ok, %{name: "ext", rel_root: nil}} = Mounts.mount_for(ext_page_abs)

      # page/1 reads the external page fine, by its absolute physical path —
      # `path`/`uri` round-trip that same absolute vocabulary.
      assert {:ok, page} = ICM.page(ext_page_abs)
      assert page.path == ext_page_abs
      assert page.content == "# External Page\n"
      assert page.uri == "icm://" <> ext_page_abs

      # create_page/2 + create_folder/2 land directly at the external mount's
      # own root (the same "" mount-relative special case embedded mounts get).
      assert {:ok, %{path: new_page_path}} = ICM.create_page(m.root, "New External")
      assert new_page_path == Path.join(m.root, "New External.md")
      assert File.exists?(new_page_path)

      assert {:ok, %{path: new_folder_path}} = ICM.create_folder(m.root, "New Folder")
      assert new_folder_path == Path.join(m.root, "New Folder")
      assert File.dir?(new_folder_path)

      # rename/2 works within the external mount.
      assert {:ok, %{path: renamed_path}} = ICM.rename(new_page_path, "Renamed External")
      assert renamed_path == Path.join(m.root, "Renamed External.md")
      refute File.exists?(new_page_path)
      assert File.exists?(renamed_path)

      # delete/1 of a page INSIDE the external mount is a legitimate
      # user-initiated editor action (binding semantic 7).
      assert {:ok, %{deleted: true}} = ICM.delete(renamed_path)
      refute File.exists?(renamed_path)

      # But never the mount root itself — Valea never deletes/moves an
      # external folder wholesale.
      assert {:error, :outside_workspace} = ICM.rename(m.root, "Hijacked")
      assert {:error, :outside_workspace} = ICM.delete(m.root)
      assert File.dir?(m.root), "mount root must remain untouched on disk"
    end

    test "a DISABLED external mount's absolute paths still get :outside_workspace from every editor op",
         %{ws: ws} do
      :ok = Mounts.set_enabled(ws, "ext", false)
      [m] = Enum.filter(Mounts.list(ws), &(&1.name == "ext"))
      ext_page_abs = Path.join(m.root, "Offers/External.md")

      # Sanity: disabled external no longer attributes via absolute path.
      assert {:error, :not_in_mount} = Mounts.mount_for(ext_page_abs)

      assert {:error, :outside_workspace} = ICM.page(ext_page_abs)
      assert {:error, :outside_workspace} = ICM.rename(ext_page_abs, "Renamed")
      assert {:error, :outside_workspace} = ICM.delete(ext_page_abs)
      assert File.exists?(ext_page_abs), "disabled external mount's file must be untouched"
    end
  end
end
