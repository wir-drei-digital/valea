defmodule Valea.Agents.ClaudeSettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.ClaudeSettings
  alias Valea.Mounts.Manifest

  setup do
    root = Path.join(System.tmp_dir!(), "vws-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

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

  defp read_perms(root) do
    root
    |> Path.join(".claude/settings.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("permissions")
  end

  # `Mounts.enabled/1` resolved-real `root` is the trustworthy expected
  # value to assert against (never the raw declared ref) — `System.tmp_dir!/0`
  # itself can be a symlink (e.g. macOS `/tmp` -> `/private/tmp`), so a raw
  # ref would mismatch the resolved allow entry `write!/1` actually emits.
  defp resolved_root(workspace, name) do
    workspace
    |> Valea.Mounts.enabled()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:root)
  end

  test "writes managed settings with deny/ask/allow contract", %{root: root} do
    :ok = ClaudeSettings.write!(root)
    settings = root |> Path.join(".claude/settings.json") |> File.read!() |> Jason.decode!()
    perms = settings["permissions"]

    assert "Read(./secrets/**)" in perms["deny"]
    assert "Read(./logs/**)" in perms["deny"]
    assert "Read(./.git/**)" in perms["deny"]
    assert "WebFetch" in perms["deny"]
    assert "WebSearch" in perms["deny"]
    assert perms["ask"] == ["Write", "Edit", "Bash"]
    # Read auto-allow is SCOPED to the workspace tree (./**). An unscoped
    # `Read` would auto-approve reads anywhere the OS user can reach, bypassing
    # PermissionPolicy entirely for reads.
    assert perms["allow"] == ["Read(./**)"]
  end

  test "idempotent — second write yields identical bytes", %{root: root} do
    :ok = ClaudeSettings.write!(root)
    first = File.read!(Path.join(root, ".claude/settings.json"))
    :ok = ClaudeSettings.write!(root)
    assert File.read!(Path.join(root, ".claude/settings.json")) == first
  end

  test "an embedded-only workspace has no absolute Read allows", %{root: root} do
    write_manifest!(Path.join([root, "mounts", "a"]), %{
      id: "d2fab426-4412-4ac0-8635-5eff502b5c6f",
      name: "A",
      description: ""
    })

    :ok = ClaudeSettings.write!(root)
    assert read_perms(root)["allow"] == ["Read(./**)"]
  end

  test "one enabled external mount adds Read(<abs>/**) to the allow list", %{root: root} do
    ext = tmp_dir!("valea-cs-ext")

    write_manifest!(ext, %{
      id: "41d871cd-aadc-466f-a951-a5c47e197d47",
      name: "Ext",
      description: ""
    })

    write_workspace_yaml!(root, """
    icms:
      ext:
        path: "#{ext}"
    """)

    ext_root = resolved_root(root, "ext")

    :ok = ClaudeSettings.write!(root)
    assert read_perms(root)["allow"] == ["Read(./**)", "Read(#{ext_root}/**)"]
  end

  test "two enabled external mounts each get their own Read(<abs>/**) allow entry", %{root: root} do
    ext_a = tmp_dir!("valea-cs-ext-a")

    write_manifest!(ext_a, %{
      id: "54261659-27ae-4d3d-b9a5-c45469520a7d",
      name: "ExtA",
      description: ""
    })

    ext_b = tmp_dir!("valea-cs-ext-b")

    write_manifest!(ext_b, %{
      id: "08c28783-f335-4f21-9d69-b3578187801b",
      name: "ExtB",
      description: ""
    })

    write_workspace_yaml!(root, """
    icms:
      ext-a:
        path: "#{ext_a}"
      ext-b:
        path: "#{ext_b}"
    """)

    ext_a_root = resolved_root(root, "ext-a")
    ext_b_root = resolved_root(root, "ext-b")

    :ok = ClaudeSettings.write!(root)

    allow = read_perms(root)["allow"]
    assert "Read(./**)" in allow
    assert "Read(#{ext_a_root}/**)" in allow
    assert "Read(#{ext_b_root}/**)" in allow
    assert length(allow) == 3
  end

  test "disabling the external mount removes its Read allow on the next write!", %{root: root} do
    ext = tmp_dir!("valea-cs-ext-disable")

    write_manifest!(ext, %{
      id: "41d871cd-aadc-466f-a951-a5c47e197d47",
      name: "Ext",
      description: ""
    })

    write_workspace_yaml!(root, """
    icms:
      ext:
        path: "#{ext}"
    """)

    ext_root = resolved_root(root, "ext")

    :ok = ClaudeSettings.write!(root)
    assert "Read(#{ext_root}/**)" in read_perms(root)["allow"]

    write_workspace_yaml!(root, """
    icms:
      ext:
        path: "#{ext}"
        enabled: false
    """)

    :ok = ClaudeSettings.write!(root)
    allow = read_perms(root)["allow"]
    refute "Read(#{ext_root}/**)" in allow
    assert allow == ["Read(./**)"]
  end

  test "an external mount whose resolved path contains glob metacharacters is excluded, does not crash",
       %{root: root} do
    parent = tmp_dir!("valea-cs-ext-parent")
    weird = Path.join(parent, "weird[1]")

    write_manifest!(weird, %{
      id: "35e0b88e-2f29-4a9e-a7dc-32c4035e5c41",
      name: "Weird",
      description: ""
    })

    write_workspace_yaml!(root, """
    icms:
      weird:
        path: "#{weird}"
    """)

    :ok = ClaudeSettings.write!(root)

    allow = read_perms(root)["allow"]
    assert allow == ["Read(./**)"]
    refute Enum.any?(allow, &String.contains?(&1, "weird"))
  end

  test "the deny block is byte-identical whether or not external mounts are enabled", %{
    root: root
  } do
    :ok = ClaudeSettings.write!(root)
    baseline_deny = read_perms(root)["deny"]

    ext = tmp_dir!("valea-cs-ext-deny")

    write_manifest!(ext, %{
      id: "41d871cd-aadc-466f-a951-a5c47e197d47",
      name: "Ext",
      description: ""
    })

    write_workspace_yaml!(root, """
    icms:
      ext:
        path: "#{ext}"
    """)

    :ok = ClaudeSettings.write!(root)
    assert read_perms(root)["deny"] == baseline_deny
  end
end
