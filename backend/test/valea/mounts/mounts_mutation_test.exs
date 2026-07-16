defmodule Valea.Mounts.MutationTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-mnt-mut-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
    end)

    %{ws: ws.path, home: dir}
  end

  # Build a real external ICM folder with a format-2 manifest — same
  # fixture idiom as `test/valea/mounts/mounts_test.exs`.
  defp icm!(base, name, id) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "icm.yaml"), "format: 2\nid: #{id}\nname: \"#{name}\"\n")
    root
  end

  # `Valea.Paths.resolve_real/2` fully symlink-resolves and is publicly
  # available; passing the same path as both `path` and `base` resolves it
  # against itself (trivially "contained"), giving the REALPATH form
  # `Mounts` itself produces (e.g. macOS's `/var` -> `/private/var`) to
  # assert against — same trick `mounts_test.exs`'s own `real!/1` uses.
  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Valea.Paths.resolve_real(expanded, expanded)
    resolved
  end

  defp last_audit_entry do
    {:ok, [entry | _]} = Valea.Audit.entries(1)
    entry
  end

  # -- mount/2 -------------------------------------------------------------

  describe "mount/2" do
    test "mounts a healthy ICM: icms: entry appears and Mounts.list shows it healthy", %{
      ws: ws,
      home: home
    } do
      root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")

      assert {:ok, %{mount_key: "coaching", id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55"}} =
               Mounts.mount(ws, root)

      assert [%{name: "coaching", root: real_root, degraded: nil, enabled: true}] =
               Mounts.list(ws)

      assert real_root == real!(root)

      entry = last_audit_entry()
      assert entry["type"] == "icm_mounted"
      assert entry["mount_key"] == "coaching"
      assert entry["id"] == "6f9f0c9e-3ccd-4fa5-a219-113a70618b55"
    end

    test "stores the path exactly as given (user's own ~-form survives)", %{ws: ws, home: home} do
      root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      assert {:ok, _} = Mounts.mount(ws, root)

      config = File.read!(Path.join(ws, "config/workspace.yaml"))
      assert config =~ root
    end

    test "derives a unique mount key from the manifest name, de-duping on collision", %{
      ws: ws,
      home: home
    } do
      a = icm!(home, "Coaching A", "31201697-cff8-4d99-9dc5-b140e4178716")
      b_dir = Path.join(home, "Coaching B")
      File.mkdir_p!(b_dir)

      File.write!(
        Path.join(b_dir, "icm.yaml"),
        "format: 2\nid: 96674b80-7a45-4b5b-9464-26c906170454\nname: \"Coaching A\"\n"
      )

      assert {:ok, %{mount_key: "coaching-a"}} = Mounts.mount(ws, a)
      assert {:ok, %{mount_key: "coaching-a-2"}} = Mounts.mount(ws, b_dir)
    end

    test "mounting a second folder with the same id fails :duplicate_id", %{ws: ws, home: home} do
      a = icm!(home, "A", "31201697-cff8-4d99-9dc5-b140e4178716")
      b = icm!(home, "B", "31201697-cff8-4d99-9dc5-b140e4178716")

      assert {:ok, _} = Mounts.mount(ws, a)
      assert {:error, :duplicate_id} = Mounts.mount(ws, b)
      assert [%{name: "a", degraded: nil}] = Mounts.list(ws)
    end

    test "mounting the same path twice fails :duplicate_root", %{ws: ws, home: home} do
      a = icm!(home, "A", "31201697-cff8-4d99-9dc5-b140e4178716")

      assert {:ok, _} = Mounts.mount(ws, a)
      assert {:error, :duplicate_root} = Mounts.mount(ws, a)
      assert [%{name: "a", degraded: nil}] = Mounts.list(ws)
    end

    test "rejects a folder with no icm.yaml with :no_manifest", %{ws: ws, home: home} do
      bare = Path.join(home, "bare")
      File.mkdir_p!(bare)
      assert {:error, :no_manifest} = Mounts.mount(ws, bare)
      assert Mounts.list(ws) == []
    end

    test "rejects a path inside the workspace", %{ws: ws} do
      assert {:error, :inside_workspace} = Mounts.mount(ws, Path.join(ws, "sources"))
    end
  end

  # -- boundary guardrails (formerly `Valea.Mounts.External.check_boundaries/2`
  # + `validate_ref/2`'s pre-write checks, inlined into `Mounts` at Phase 11) --

  describe "mount/2 boundary guardrails" do
    test "rejects a relative path with :not_absolute", %{ws: ws} do
      assert {:error, :not_absolute} = Mounts.mount(ws, "relative/path")
    end

    test "rejects the home directory with :home_or_root", %{ws: ws} do
      assert {:error, :home_or_root} = Mounts.mount(ws, System.user_home!())
    end

    test "rejects the filesystem root with :home_or_root", %{ws: ws} do
      assert {:error, :home_or_root} = Mounts.mount(ws, "/")
    end

    test "rejects an ancestor of the workspace with :ancestor_of_workspace", %{ws: ws, home: home} do
      assert {:error, :ancestor_of_workspace} = Mounts.mount(ws, home)
    end

    test "rejects a path with a permission-glob metacharacter with :unsafe_path", %{
      ws: ws,
      home: home
    } do
      unsafe = Path.join(home, "weird*name")
      assert {:error, :unsafe_path} = Mounts.mount(ws, unsafe)
    end
  end

  # -- create/3 (icms: + portable template seed) ---------------------------

  describe "create/3" do
    test "mints a UUID, seeds the portable template, writes a fresh icm.yaml, mounts it", %{
      ws: ws,
      home: home
    } do
      target = Path.join(home, "Coaching")

      assert {:ok, %{mount_key: "coaching", id: id}} = Mounts.create(ws, "Coaching", target)
      assert {:ok, _} = Ecto.UUID.cast(id)

      refute File.dir?(Path.join(target, "Workflows"))
      assert File.exists?(Path.join(target, "Decisions/2026.md"))
      assert File.exists?(Path.join(target, "Templates/Client.md"))
      assert File.exists?(Path.join(target, "Templates/Decision.md"))
      assert File.exists?(Path.join(target, "CONTEXT.md"))
      assert File.exists?(Path.join(target, "CLAUDE.md"))

      icm_yaml = File.read!(Path.join(target, "icm.yaml"))
      assert icm_yaml =~ "format: 2"
      assert icm_yaml =~ "id: \"#{id}\""
      assert icm_yaml =~ "name: \"Coaching\""

      agents_md = File.read!(Path.join(target, "AGENTS.md"))
      assert agents_md =~ "Coaching"
      refute agents_md =~ "{{name}}"

      context_md = File.read!(Path.join(target, "CONTEXT.md"))
      refute context_md =~ "{{name}}"

      assert [%{name: "coaching", root: root, degraded: nil, enabled: true}] = Mounts.list(ws)
      assert root == real!(target)
    end

    test "refuses to clobber a folder that already holds an icm.yaml", %{ws: ws, home: home} do
      existing = icm!(home, "Existing", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      assert {:error, :already_exists} = Mounts.create(ws, "Existing", existing)
    end

    test "rejects a blank name", %{ws: ws, home: home} do
      target = Path.join(home, "Blank")
      assert {:error, :invalid_mount_name} = Mounts.create(ws, "   ", target)
      refute File.exists?(target)
    end
  end

  # -- set_enabled/3 --------------------------------------------------------

  describe "set_enabled/3" do
    test "flips enabled and audits icm_enabled/icm_disabled", %{ws: ws, home: home} do
      root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      {:ok, _} = Mounts.mount(ws, root)

      assert :ok = Mounts.set_enabled(ws, "coaching", false)
      assert [%{name: "coaching", enabled: false}] = Mounts.list(ws)
      assert last_audit_entry()["type"] == "icm_disabled"

      assert :ok = Mounts.set_enabled(ws, "coaching", true)
      assert [%{name: "coaching", enabled: true}] = Mounts.list(ws)
      assert last_audit_entry()["type"] == "icm_enabled"
    end

    test "an unknown mount key fails :mount_not_found", %{ws: ws} do
      assert {:error, :mount_not_found} = Mounts.set_enabled(ws, "nope", false)
    end
  end

  # -- unmount/2 -------------------------------------------------------------

  describe "unmount/2" do
    test "removes the config entry and leaves the folder intact", %{ws: ws, home: home} do
      root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      {:ok, _} = Mounts.mount(ws, root)

      assert {:ok, resolved} = Mounts.unmount(ws, "coaching")
      assert resolved == real!(root)
      assert Mounts.list(ws) == []
      assert File.exists?(Path.join(root, "icm.yaml"))
      assert last_audit_entry()["type"] == "icm_unmounted"
    end

    test "an unknown mount key fails :mount_not_found", %{ws: ws} do
      assert {:error, :mount_not_found} = Mounts.unmount(ws, "nope")
    end
  end

  # -- preserves unrelated top-level config keys ----------------------------

  describe "config preservation" do
    test "mutations preserve version/id/name and an unrelated legacy mounts: section", %{
      ws: ws,
      home: home
    } do
      path = Path.join(ws, "config/workspace.yaml")
      original = File.read!(path)
      assert original =~ "name:"

      base = original |> String.split("icms:") |> hd()

      File.write!(
        path,
        base <>
          "icms: {}\nmounts:\n  legacy:\n    kind: path\n    ref: \"/tmp/legacy\"\n"
      )

      root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      assert {:ok, _} = Mounts.mount(ws, root)

      updated = File.read!(path)
      assert updated =~ ~r/^version: 5$/m
      assert updated =~ "name:"
      assert updated =~ "legacy:"
      assert updated =~ "ref: \"/tmp/legacy\""
    end
  end
end
