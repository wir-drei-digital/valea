defmodule Valea.Mounts.ExternalTest do
  use ExUnit.Case, async: true

  alias Valea.Mounts.External
  alias Valea.Mounts.Manifest
  alias Valea.Paths

  defp tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_manifest!(mount_dir, attrs) do
    File.mkdir_p!(mount_dir)
    File.write!(Path.join(mount_dir, "icm.yaml"), Manifest.render(attrs))
  end

  defp write_workspace_yaml!(root, contents) do
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), contents)
  end

  # `Valea.Paths.resolve_real/2` fully symlink-resolves and is publicly
  # available; passing the same path as both `path` and `base` resolves it
  # against itself (trivially "contained"), giving the expected REALPATH
  # form to assert against — same trick this module's `resolve_best_effort/1`
  # uses internally.
  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Paths.resolve_real(expanded, expanded)
    resolved
  end

  describe "declared/1" do
    test "a valid external ref resolves to a mount struct: abs root, rel_root nil, manifest loaded" do
      ws = tmp_dir!("valea-ext-ws")
      ext = tmp_dir!("valea-ext-target")
      write_manifest!(ext, %{id: "ext-id", name: "External ICM", description: "d"})

      write_workspace_yaml!(ws, """
      version: 4
      id: ws-id
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.name == "outside"
      assert mount.rel_root == nil
      assert mount.root == real!(ext)
      assert mount.degraded == nil
      assert mount.enabled == true
      assert %Manifest{name: "External ICM", description: "d"} = mount.manifest
    end

    test "config enabled: false is preserved on the struct" do
      ws = tmp_dir!("valea-ext-ws")
      ext = tmp_dir!("valea-ext-target")
      write_manifest!(ext, %{id: "ext-id", name: "External", description: ""})

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
          enabled: false
      """)

      assert [mount] = External.declared(ws)
      assert mount.enabled == false
    end

    test "a ref that no longer resolves to a folder is degraded :not_found, config preserved" do
      ws = tmp_dir!("valea-ext-ws")
      missing_ref = Path.join(tmp_dir!("valea-ext-parent"), "does-not-exist")

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "#{missing_ref}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.name == "outside"
      assert mount.rel_root == nil
      assert mount.manifest == nil
      # never dropped -- the entry, and its enabled flag, survive.
      assert mount.enabled == true
      assert mount.degraded =~ "folder not found at"
      assert mount.degraded =~ missing_ref
    end

    test "a ref resolving to a FILE (not a folder) is degraded :not_found" do
      ws = tmp_dir!("valea-ext-ws")
      parent = tmp_dir!("valea-ext-parent")
      file_ref = Path.join(parent, "just-a-file.txt")
      File.write!(file_ref, "not a folder")

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "#{file_ref}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.degraded =~ "folder not found at"
    end

    test "a ref without icm.yaml degrades with the same vocabulary as an embedded mount" do
      ws = tmp_dir!("valea-ext-ws")
      ext = tmp_dir!("valea-ext-target")

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.manifest == nil
      assert mount.degraded == "icm.yaml is missing"
      assert mount.root == real!(ext)
    end

    test "a ref with an invalid icm.yaml degrades with the manifest's own reason" do
      ws = tmp_dir!("valea-ext-ws")
      ext = tmp_dir!("valea-ext-target")
      File.write!(Path.join(ext, "icm.yaml"), "name: [unterminated")

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "#{ext}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.manifest == nil
      assert is_binary(mount.degraded)
      assert mount.degraded != "icm.yaml is missing"
    end

    test "only kind: path entries are selected -- git/embedded-relationship entries are ignored" do
      ws = tmp_dir!("valea-ext-ws")

      write_workspace_yaml!(ws, """
      mounts:
        embedded_rel:
          enabled: false
        future_git:
          kind: git
          ref: "origin/main"
      """)

      assert External.declared(ws) == []
    end

    test "no mounts: section at all yields an empty list" do
      ws = tmp_dir!("valea-ext-ws")
      write_workspace_yaml!(ws, "version: 4\nid: ws-id\n")

      assert External.declared(ws) == []
    end

    test "sorted by name, multiple external mounts" do
      ws = tmp_dir!("valea-ext-ws")
      ext_z = tmp_dir!("valea-ext-z")
      ext_a = tmp_dir!("valea-ext-a")
      write_manifest!(ext_z, %{id: "z", name: "Z", description: ""})
      write_manifest!(ext_a, %{id: "a", name: "A", description: ""})

      write_workspace_yaml!(ws, """
      mounts:
        zeta:
          kind: path
          ref: "#{ext_z}"
        alpha:
          kind: path
          ref: "#{ext_a}"
      """)

      assert [%{name: "alpha"}, %{name: "zeta"}] = External.declared(ws)
    end

    test "symlink to a valid ICM resolves to its real (target) path" do
      ws = tmp_dir!("valea-ext-ws")
      real_target = tmp_dir!("valea-ext-real-target")
      write_manifest!(real_target, %{id: "sym-id", name: "Symlinked", description: ""})

      link_parent = tmp_dir!("valea-ext-link-parent")
      link = Path.join(link_parent, "link-to-icm")
      File.ln_s!(real_target, link)

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "#{link}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.root == real!(real_target)
      refute mount.root == Path.expand(link)
      assert %Manifest{name: "Symlinked"} = mount.manifest
    end

    test "an entry missing the ref key entirely does not crash discovery" do
      ws = tmp_dir!("valea-ext-ws")

      write_workspace_yaml!(ws, """
      mounts:
        broken:
          kind: path
      """)

      assert [mount] = External.declared(ws)
      assert mount.name == "broken"
      assert mount.manifest == nil
      assert is_binary(mount.degraded)
    end
  end

  describe "declared/1 -- read-path guardrails (hand-edited config must not mint a clean mount)" do
    test "an ancestor-of-workspace ref is degraded even when a manifest is reachable there" do
      parent = tmp_dir!("valea-ext-parent")
      ws = Path.join(parent, "the-workspace")
      File.mkdir_p!(ws)
      # A manifest AT the ancestor — proves the guardrail fires before (and
      # regardless of) manifest loading.
      write_manifest!(parent, %{id: "evil", name: "Evil Ancestor", description: ""})

      write_workspace_yaml!(ws, """
      mounts:
        evil:
          kind: path
          ref: "#{parent}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.name == "evil"
      assert mount.manifest == nil
      assert mount.degraded =~ "ancestor"
      # config preserved: the entry still surfaces; root carries the resolved
      # path; `degraded != nil` is what excludes it from any effective set
      # (the `effective?/1` convention every consumer composes over).
      assert mount.root == real!(parent)
      assert mount.enabled == true
    end

    test "ref == the workspace root itself is degraded" do
      ws = tmp_dir!("valea-ext-ws")
      write_manifest!(ws, %{id: "self", name: "Self", description: ""})

      write_workspace_yaml!(ws, """
      mounts:
        selfref:
          kind: path
          ref: "#{ws}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.manifest == nil
      assert is_binary(mount.degraded)
      assert mount.degraded =~ "workspace"
    end

    test "a ref inside the workspace is degraded" do
      ws = tmp_dir!("valea-ext-ws")
      inside = Path.join(ws, "nested/icm")
      write_manifest!(inside, %{id: "in", name: "Inside", description: ""})

      write_workspace_yaml!(ws, """
      mounts:
        insider:
          kind: path
          ref: "#{inside}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.manifest == nil
      assert mount.degraded =~ "workspace"
    end

    test "a symlink ref resolving inside the workspace is degraded (guardrail runs on the resolved path)" do
      ws = tmp_dir!("valea-ext-ws")
      inside = Path.join(ws, "target")
      write_manifest!(inside, %{id: "in", name: "Inside", description: ""})

      link_parent = tmp_dir!("valea-ext-link-parent")
      link = Path.join(link_parent, "sneaky")
      File.ln_s!(inside, link)

      write_workspace_yaml!(ws, """
      mounts:
        sneaky:
          kind: path
          ref: "#{link}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.manifest == nil
      assert mount.degraded =~ "workspace"
    end

    test "a relative ref is degraded, never anchored to the process CWD" do
      ws = tmp_dir!("valea-ext-ws")

      write_workspace_yaml!(ws, """
      mounts:
        rel:
          kind: path
          ref: "some/relative/dir"
      """)

      assert [mount] = External.declared(ws)
      assert mount.manifest == nil
      assert mount.degraded =~ "absolute"
    end
  end

  # $HOME cannot be faked at runtime (see the ~-expansion note below), and
  # declaring the REAL $HOME as a config ref in a test would depend on
  # whether the developer's home happens to contain an icm.yaml — so the
  # home-or-root arm of the READ path is exercised directly on the shared
  # guardrail function both `declared/1` and `validate_ref/2` call.
  describe "check_boundaries/2 (shared guardrail)" do
    test "rejects the realpath-resolved $HOME even when a manifest would be reachable there" do
      ws = real!(tmp_dir!("valea-ext-ws"))
      home = real!(System.user_home!())

      assert {:error, :home_or_root} = External.check_boundaries(home, ws)
    end

    test "rejects / literally" do
      ws = real!(tmp_dir!("valea-ext-ws"))
      assert {:error, :home_or_root} = External.check_boundaries("/", ws)
    end

    test "accepts an unrelated sibling path (segment boundary, not string prefix)" do
      parent = real!(tmp_dir!("valea-ext-parent"))
      ws = Path.join(parent, "ws")
      sibling = Path.join(parent, "ws-other")

      assert :ok = External.check_boundaries(sibling, ws)
    end

    test "classifies self/inside/ancestor relationships" do
      parent = real!(tmp_dir!("valea-ext-parent"))
      ws = Path.join(parent, "ws")

      assert {:error, :inside_workspace} = External.check_boundaries(ws, ws)
      assert {:error, :inside_workspace} = External.check_boundaries(Path.join(ws, "sub"), ws)
      assert {:error, :ancestor_of_workspace} = External.check_boundaries(parent, ws)
    end
  end

  # ~-expansion cannot be exercised by overriding the HOME env var at
  # runtime: `System.user_home!/0` reads `:init.get_argument(:home)`, which
  # the BEAM captures once at VM boot from the OS environment and never
  # re-reads (verified: `System.put_env("HOME", ...)` does not change
  # `Path.expand("~")` within a running node). So this test plants a real,
  # uniquely-named, self-cleaning fixture directly under the actual $HOME.
  describe "~ expansion" do
    test "declared/1 expands ~ in ref against the real $HOME" do
      unique =
        "valea-ext-tilde-test-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"

      home_child = Path.join(System.user_home!(), unique)
      on_exit(fn -> File.rm_rf!(home_child) end)
      write_manifest!(home_child, %{id: "tilde-id", name: "Tilde", description: ""})

      ws = tmp_dir!("valea-ext-ws")

      write_workspace_yaml!(ws, """
      mounts:
        outside:
          kind: path
          ref: "~/#{unique}"
      """)

      assert [mount] = External.declared(ws)
      assert mount.root == real!(home_child)
      assert %Manifest{name: "Tilde"} = mount.manifest
    end

    test "validate_ref expands ~ before running guardrails" do
      unique =
        "valea-ext-tilde-vr-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"

      home_child = Path.join(System.user_home!(), unique)
      on_exit(fn -> File.rm_rf!(home_child) end)
      write_manifest!(home_child, %{id: "tilde-id", name: "Tilde", description: ""})

      ws = tmp_dir!("valea-ext-ws")

      assert {:ok, resolved} = External.validate_ref(ws, "~/#{unique}")
      assert resolved == real!(home_child)
    end
  end

  describe "validate_ref/2 -- guardrails" do
    setup do
      %{ws: tmp_dir!("valea-ext-ws")}
    end

    test "accepts a valid external ref outside the workspace, home, and root", %{ws: ws} do
      ext = tmp_dir!("valea-ext-target")
      write_manifest!(ext, %{id: "id", name: "N", description: ""})

      assert {:ok, resolved} = External.validate_ref(ws, ext)
      assert resolved == real!(ext)
    end

    test "rejects a ref inside the workspace", %{ws: ws} do
      inside = Path.join(ws, "some/nested/dir")
      File.mkdir_p!(inside)

      assert {:error, :inside_workspace} = External.validate_ref(ws, inside)
    end

    test "rejects the workspace root itself", %{ws: ws} do
      assert {:error, :inside_workspace} = External.validate_ref(ws, ws)
    end

    test "rejects a ref that is an ancestor of the workspace (segment-boundary, not lexical prefix)" do
      parent = tmp_dir!("valea-ext-parent")
      ws = Path.join(parent, "the-workspace")
      File.mkdir_p!(ws)

      assert {:error, :ancestor_of_workspace} = External.validate_ref(ws, parent)
    end

    test "does NOT treat a sibling with a shared string prefix as inside or ancestor" do
      parent = tmp_dir!("valea-ext-parent")
      ws = Path.join(parent, "ws")
      sibling = Path.join(parent, "ws-other")
      File.mkdir_p!(ws)
      write_manifest!(sibling, %{id: "sib", name: "Sibling", description: ""})

      assert {:ok, _resolved} = External.validate_ref(ws, sibling)
    end

    test "rejects $HOME exactly", %{ws: ws} do
      assert {:error, :home_or_root} = External.validate_ref(ws, System.user_home!())
    end

    test "rejects / exactly", %{ws: ws} do
      assert {:error, :home_or_root} = External.validate_ref(ws, "/")
    end

    test "rejects a bare ~ (resolves to $HOME) as :home_or_root", %{ws: ws} do
      assert {:error, :home_or_root} = External.validate_ref(ws, "~")
    end

    test "rejects a relative ref as :not_absolute -- never anchored to the process CWD", %{
      ws: ws
    } do
      assert {:error, :not_absolute} = External.validate_ref(ws, "some/relative/dir")
      assert {:error, :not_absolute} = External.validate_ref(ws, "./dot-relative")
      assert {:error, :not_absolute} = External.validate_ref(ws, "../up-relative")
      # `~user` home lookups are not supported by Path.expand -- it would fall
      # back to a CWD-relative literal, so it is rejected the same way.
      assert {:error, :not_absolute} = External.validate_ref(ws, "~otheruser/icm")
      assert {:error, :not_absolute} = External.validate_ref(ws, "")
    end

    test "rejects a ref that does not resolve to any folder", %{ws: ws} do
      missing = Path.join(tmp_dir!("valea-ext-parent"), "nope")
      assert {:error, :not_found} = External.validate_ref(ws, missing)
    end

    test "rejects a ref that resolves to a FILE, not a folder", %{ws: ws} do
      parent = tmp_dir!("valea-ext-parent")
      file_ref = Path.join(parent, "file.txt")
      File.write!(file_ref, "x")

      assert {:error, :not_found} = External.validate_ref(ws, file_ref)
    end

    test "rejects a folder with no icm.yaml", %{ws: ws} do
      ext = tmp_dir!("valea-ext-target")
      assert {:error, :no_manifest} = External.validate_ref(ws, ext)
    end

    test "rejects a folder with an invalid icm.yaml", %{ws: ws} do
      ext = tmp_dir!("valea-ext-target")
      File.write!(Path.join(ext, "icm.yaml"), "name: [unterminated")

      assert {:error, {:invalid_manifest, reason}} = External.validate_ref(ws, ext)
      assert is_binary(reason)
    end

    test "resolves a symlink to its real path before applying guardrails", %{ws: ws} do
      real_target = tmp_dir!("valea-ext-real-target")
      write_manifest!(real_target, %{id: "id", name: "N", description: ""})

      link_parent = tmp_dir!("valea-ext-link-parent")
      link = Path.join(link_parent, "link")
      File.ln_s!(real_target, link)

      assert {:ok, resolved} = External.validate_ref(ws, link)
      assert resolved == real!(real_target)
    end

    test "a symlink that ultimately resolves inside the workspace is rejected as inside_workspace",
         %{ws: ws} do
      inside = Path.join(ws, "target")
      File.mkdir_p!(inside)

      link_parent = tmp_dir!("valea-ext-link-parent")
      link = Path.join(link_parent, "sneaky-link")
      File.ln_s!(inside, link)

      assert {:error, :inside_workspace} = External.validate_ref(ws, link)
    end
  end
end
