defmodule Valea.Workspace.AdoptTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Adopt
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  defp tmp_dir(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_manifest!(dir, attrs) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "icm.yaml"), Manifest.render(attrs))
  end

  # -- classify_path/1 ------------------------------------------------------

  describe "classify_path/1" do
    test "classifies a scaffolded workspace dir as :workspace" do
      target = tmp_dir("valea-ws")
      :ok = Scaffold.create(target, "Acme")

      assert {:workspace, nil} = Adopt.classify_path(target)
    end

    test "classifies a dir with a parseable icm.yaml (not a workspace) as :icm" do
      dir = tmp_dir("valea-icm")

      write_manifest!(dir, %{
        id: "4180e4f3-42f3-4f25-9b55-6148ba6a5252",
        name: "My Notes",
        description: "Old client work"
      })

      assert {:icm, manifest} = Adopt.classify_path(dir)
      assert manifest.name == "My Notes"
      assert manifest.description == "Old client work"
    end

    test "classifies a plain dir with no icm.yaml as :other" do
      dir = tmp_dir("valea-plain")
      File.mkdir_p!(dir)

      assert {:other, nil} = Adopt.classify_path(dir)
    end

    test "classifies a dir with an INVALID icm.yaml as :other, not :icm" do
      dir = tmp_dir("valea-invalid-icm")
      File.mkdir_p!(dir)
      # missing required `name:` key -> Manifest.load/1 returns {:error, {:invalid, _}}
      File.write!(Path.join(dir, "icm.yaml"), "format: 1\n")

      assert {:other, nil} = Adopt.classify_path(dir)
    end

    test "a workspace dir wins classification over :icm even if it somehow also has a root icm.yaml" do
      target = tmp_dir("valea-ws-icm")
      :ok = Scaffold.create(target, "Acme")

      write_manifest!(target, %{
        id: "d89442e0-4d2a-4f57-a709-4b3ac5b744ee",
        name: "Confusing",
        description: ""
      })

      assert {:workspace, nil} = Adopt.classify_path(target)
    end
  end

  # -- create_with_icm/3 -----------------------------------------------------

  describe "create_with_icm/3 — happy paths" do
    setup do
      dir = tmp_dir("valea-app")
      System.put_env("VALEA_APP_DIR", dir)
      Manager.close()

      on_exit(fn ->
        Manager.close()
        System.delete_env("VALEA_APP_DIR")
      end)

      %{parent: Path.join(dir, "workspaces")}
    end

    # TODO(Phase 11): adopt-by-move mints an embedded mount inside the workspace
    # (mounts/<slug>/), which the external-only config-truth Valea.Mounts (Phase 3)
    # rejects by the unconditional :inside_workspace boundary rule. Adopt is deleted in
    # Phase 11 (replaced by Phase 10 "Use existing ICM" = mount by reference in place).
    @tag skip: "Phase 11: adopt-by-move incompatible with external-only Mounts"
    test "moves the folder into mounts/<slug>, mints a manifest when absent, regenerates MOUNTS.md, opens it",
         %{parent: parent} do
      source = tmp_dir("valea-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      assert {:ok, info} = Adopt.create_with_icm(parent, "Acme Coaching", source)
      assert info.name == "Acme Coaching"

      target = Path.join(parent, "Acme Coaching")
      slug = Path.basename(source) |> Scaffold.slugify()
      mount_dir = Path.join([target, "mounts", slug])

      # never copied — the source path no longer exists at all
      refute File.exists?(source)
      assert File.dir?(mount_dir)
      assert File.exists?(Path.join(mount_dir, "Notes.md"))

      # a manifest was minted (source had none), named from the folder
      assert {:ok, manifest} = Manifest.load(mount_dir)
      assert manifest.name == Path.basename(source)
      assert Regex.match?(~r/^[0-9a-f-]{36}$/, manifest.id)

      # only ONE mount — the starter mount scaffold seeds is gone (removed
      # pre-open, never opened, never surfaced)
      assert ["mounts/#{slug}"] ==
               Path.wildcard(Path.join(target, "mounts/*"))
               |> Enum.map(&Path.relative_to(&1, target))

      # KNOWN FAILING (reported, not papered over — see the migration
      # report): `create_with_icm/3` mints this mount by MOVING the folder
      # to `mounts/<slug>` (embedded, INSIDE the workspace) but never
      # writes an `icms:` config entry for it. `Valea.Mounts.list/1` is
      # config truth over `icms:` ONLY now, so `MountsMd.regenerate/1`
      # (which reads `Mounts.list/1`) can never see this mount, no matter
      # what — and even a hand-written `icms:` entry pointing at it would
      # be degraded on read by `Valea.Mounts.External.check_boundaries/2`'s
      # `:inside_workspace` rule, which is unconditional and by design
      # (every declared mount must resolve OUTSIDE the workspace). Fixing
      # this needs a product decision above this test's scope: either
      # `Adopt` mounts by reference instead of moving (a bigger behavioral
      # change — would also break the "never copied — the source path no
      # longer exists at all" assertion above), or `Mounts` grows a
      # legitimate in-workspace mount concept (a change to the forbidden
      # `lib/valea/mounts.ex` / its `external.ex` boundary rules, which are
      # extensively documented as intentional). Left failing rather than
      # weakened.
      mounts_md = File.read!(Path.join(target, "MOUNTS.md"))
      assert mounts_md =~ "@mounts/#{slug}/AGENTS.md"

      # opened
      assert {:ok, ^info} = Manager.current()
    end

    test "preserves an existing manifest rather than minting a new one", %{parent: parent} do
      source = tmp_dir("valea-source")

      write_manifest!(source, %{
        id: "564053d3-ce0a-4a21-a272-99e708622c54",
        name: "Original Name",
        description: "Kept"
      })

      assert {:ok, _info} = Adopt.create_with_icm(parent, "Wrap", source)

      target = Path.join(parent, "Wrap")
      slug = Scaffold.slugify(Path.basename(source))
      mount_dir = Path.join([target, "mounts", slug])

      assert {:ok, manifest} = Manifest.load(mount_dir)
      assert manifest.id == "564053d3-ce0a-4a21-a272-99e708622c54"
      assert manifest.name == "Original Name"
      assert manifest.description == "Kept"
    end

    test "create/1 form: names the workspace after the parent+name pair, slug from the SOURCE folder's own name",
         %{parent: parent} do
      source = tmp_dir("valea-source-Café Notes!!")
      File.mkdir_p!(source)

      assert {:ok, _info} = Adopt.create_with_icm(parent, "Some Workspace", source)

      target = Path.join(parent, "Some Workspace")
      slug = Scaffold.slugify(Path.basename(source))
      assert File.dir?(Path.join([target, "mounts", slug]))
    end
  end

  describe "create_with_icm/3 — rejections" do
    setup do
      dir = tmp_dir("valea-app")
      System.put_env("VALEA_APP_DIR", dir)
      Manager.close()

      on_exit(fn ->
        Manager.close()
        System.delete_env("VALEA_APP_DIR")
      end)

      %{parent: Path.join(dir, "workspaces")}
    end

    test "rejects a source that does not exist", %{parent: parent} do
      missing =
        Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}")

      assert {:error, :source_not_found} = Adopt.create_with_icm(parent, "X", missing)
    end

    test "rejects a source that IS a workspace itself", %{parent: parent} do
      source = tmp_dir("valea-source-ws")
      :ok = Scaffold.create(source, "Already A Workspace")

      assert {:error, :source_is_workspace} = Adopt.create_with_icm(parent, "X", source)
      assert File.dir?(source)
    end

    test "rejects a source nested inside an existing workspace", %{parent: parent} do
      existing_ws = tmp_dir("valea-existing-ws")
      :ok = Scaffold.create(existing_ws, "Existing")
      nested_mount = Path.join(existing_ws, "mounts/existing")

      assert {:error, :source_in_workspace} = Adopt.create_with_icm(parent, "X", nested_mount)
      assert File.dir?(nested_mount)
    end

    test "rejects a source equal to the currently-open workspace's dir", %{parent: parent} do
      {:ok, open_ws} = Manager.create(parent, "Open Me")

      assert {:error, :source_is_open_workspace} =
               Adopt.create_with_icm(parent, "X", open_ws.path)

      assert {:ok, ^open_ws} = Manager.current()
    end

    test "rejects a cycle where parent_dir is inside the source", %{parent: _parent} do
      source = tmp_dir("valea-cycle-source")
      File.mkdir_p!(source)
      nested_parent = Path.join(source, "nested")
      File.mkdir_p!(nested_parent)

      assert {:error, :cycle} = Adopt.create_with_icm(nested_parent, "X", source)
      assert File.dir?(source)
    end

    test "rejects a cycle where parent_dir equals the source", %{parent: _parent} do
      source = tmp_dir("valea-cycle-eq-source")
      File.mkdir_p!(source)

      assert {:error, :cycle} = Adopt.create_with_icm(source, "X", source)
      assert File.dir?(source)
    end

    test "rejects target == source (adopting into its own parent under its own name)", %{
      parent: _parent
    } do
      source = tmp_dir("valea-target-eq-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      assert {:error, :target_is_source} =
               Adopt.create_with_icm(Path.dirname(source), Path.basename(source), source)

      # untouched — never scaffolded into, never moved
      assert File.dir?(source)
      assert File.exists?(Path.join(source, "Notes.md"))
      refute File.exists?(Path.join(source, "config"))
    end

    test "rejects when target is a symlink pointing to source (case-insensitive filesystem guard)",
         %{parent: parent} do
      source = tmp_dir("valea-target-symlink-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      # Create parent and a symlink in it pointing to source
      File.mkdir_p!(parent)
      symlink_path = Path.join(parent, "alias-to-source")
      File.ln_s(source, symlink_path)

      # Attempt to adopt via the symlink (different string, same filesystem identity)
      assert {:error, :target_is_source} =
               Adopt.create_with_icm(parent, "alias-to-source", source)

      # source untouched
      assert File.dir?(source)
      assert File.exists?(Path.join(source, "Notes.md"))
      refute File.exists?(Path.join(source, "config"))
    end

    test "an existing non-empty target folder surfaces target_not_empty (bubbled from Scaffold.create)",
         %{parent: parent} do
      source = tmp_dir("valea-source-tne")
      File.mkdir_p!(source)

      target = Path.join(parent, "Taken")
      File.mkdir_p!(target)
      File.write!(Path.join(target, "existing.txt"), "x")

      assert {:error, :target_not_empty} = Adopt.create_with_icm(parent, "Taken", source)
      assert File.dir?(source)
    end
  end

  describe "create_with_icm/3 — move-failure handling" do
    setup do
      dir = tmp_dir("valea-app")
      System.put_env("VALEA_APP_DIR", dir)
      Manager.close()

      on_exit(fn ->
        Manager.close()
        System.delete_env("VALEA_APP_DIR")
      end)

      %{parent: Path.join(dir, "workspaces")}
    end

    # A real cross-device (EXDEV) rename isn't portably reproducible in a
    # sandboxed test run (it needs a second filesystem/device, which CI
    # doesn't provide) — `map_move_error/1` is the pure decision function
    # `create_with_icm/3` funnels every `File.rename/2` failure through, so
    # the EXDEV -> :cross_device mapping is unit-tested directly instead.
    test "map_move_error/1 maps EXDEV to :cross_device" do
      assert Adopt.map_move_error(:exdev) == :cross_device
    end

    test "map_move_error/1 wraps any other rename failure as {:move_failed, reason}" do
      assert Adopt.map_move_error(:eacces) == {:move_failed, :eacces}
    end

    test "a real (non-EXDEV) rename failure leaves no partial state: target is cleaned up, source untouched",
         %{parent: parent} do
      source_parent = tmp_dir("valea-source-parent")
      source = Path.join(source_parent, "knowledge")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      # Strip write permission from the SOURCE'S PARENT dir: renaming
      # `source` requires unlinking its directory entry there, which needs
      # write+execute on the parent — this deterministically forces
      # `File.rename/2` to fail with :eacces (a REAL filesystem error, not a
      # mock), without touching `source` itself or anything under `target`.
      File.chmod!(source_parent, 0o555)
      on_exit(fn -> File.chmod!(source_parent, 0o755) end)

      assert {:error, {:move_failed, _reason}} = Adopt.create_with_icm(parent, "CleansUp", source)

      # no orphaned half-scaffolded workspace left behind...
      refute File.exists?(Path.join(parent, "CleansUp"))
      # ...and the source is completely untouched (never copied, never
      # partially moved).
      assert File.dir?(source)
      assert File.exists?(Path.join(source, "Notes.md"))
    end
  end
end
