defmodule Valea.Mounts.MountsMdTest do
  use ExUnit.Case, async: true

  alias Valea.Mounts.MountsMd

  setup do
    root = Path.join(System.tmp_dir!(), "vmountsmd-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_manifest!(root, name, attrs) do
    dir = Path.join([root, "mounts", name])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "icm.yaml"), """
    format: 1
    id: "#{Ecto.UUID.generate()}"
    name: #{attrs[:name] |> inspect()}
    description: #{attrs[:description] |> inspect()}
    """)

    dir
  end

  defp write_config!(root, contents) do
    config_dir = Path.join(root, "config")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, "workspace.yaml"), contents)
  end

  defp mounts_md(root), do: Path.join(root, "MOUNTS.md")

  # Two enabled mounts (alpha, beta), one disabled-but-fine mount (gamma),
  # two degraded mounts: delta (icm.yaml missing entirely) and epsilon
  # (icm.yaml present but invalid — blank name), so both degraded branches
  # of `Valea.Mounts.list/1` (manifest: nil from EITHER `{:error, :missing}`
  # or `{:error, {:invalid, _}}`) are exercised.
  defp seed_mixed_mounts!(root) do
    write_manifest!(root, "alpha", name: "Alpha ICM", description: "Alpha desc")
    write_manifest!(root, "beta", name: "Beta ICM", description: "Beta desc")
    write_manifest!(root, "gamma", name: "Gamma ICM", description: "Gamma desc")

    delta_dir = Path.join([root, "mounts", "delta"])
    File.mkdir_p!(delta_dir)

    epsilon_dir = Path.join([root, "mounts", "epsilon"])
    File.mkdir_p!(epsilon_dir)
    File.write!(Path.join(epsilon_dir, "icm.yaml"), "name: \"   \"\n")

    write_config!(root, """
    version: 1
    mounts:
      gamma:
        enabled: false
    """)

    :ok
  end

  describe "regenerate/1 — enabled mounts" do
    setup %{root: root} do
      seed_mixed_mounts!(root)
      :ok = MountsMd.regenerate(root)
      %{content: File.read!(mounts_md(root))}
    end

    test "emits an @-ref block for each enabled mount", %{content: content} do
      assert content =~ "@mounts/alpha/AGENTS.md"
      assert content =~ "@mounts/beta/AGENTS.md"
    end

    test "enabled block carries the manifest name, description, and path", %{content: content} do
      assert content =~ "### Alpha ICM"
      assert content =~ "Alpha desc"
      assert content =~ "path: mounts/alpha"

      assert content =~ "### Beta ICM"
      assert content =~ "Beta desc"
      assert content =~ "path: mounts/beta"
    end

    test "does not emit an @-ref for the disabled or degraded mounts", %{content: content} do
      refute content =~ "@mounts/gamma/AGENTS.md"
      refute content =~ "@mounts/delta/AGENTS.md"
      refute content =~ "@mounts/epsilon/AGENTS.md"
    end
  end

  describe "regenerate/1 — disabled mounts" do
    setup %{root: root} do
      seed_mixed_mounts!(root)
      :ok = MountsMd.regenerate(root)
      %{content: File.read!(mounts_md(root))}
    end

    test "lists the disabled mount under Deactivated", %{content: content} do
      assert content =~ "## Deactivated"
      assert content =~ "Gamma ICM"
    end

    test "the disabled mount is never rendered as an enabled ### block", %{content: content} do
      refute content =~ "### Gamma ICM"
    end
  end

  describe "regenerate/1 — degraded mounts" do
    setup %{root: root} do
      seed_mixed_mounts!(root)
      :ok = MountsMd.regenerate(root)
      %{content: File.read!(mounts_md(root))}
    end

    test "lists each degraded mount under Needs attention with its reason", %{content: content} do
      assert content =~ "## Needs attention"
      assert content =~ "delta"
      assert content =~ "icm.yaml is missing"
      assert content =~ "epsilon"
      assert content =~ "name must not be blank"
    end

    test "degraded mounts never get an @-ref (manifest is nil, must not be dereferenced)", %{
      content: content
    } do
      refute content =~ "@mounts/delta/AGENTS.md"
      refute content =~ "@mounts/epsilon/AGENTS.md"
    end
  end

  describe "regenerate/1 — atomicity and determinism" do
    test "leaves no stray .tmp file behind", %{root: root} do
      seed_mixed_mounts!(root)
      :ok = MountsMd.regenerate(root)
      refute File.exists?(mounts_md(root) <> ".tmp")
    end

    test "is idempotent: regenerating twice from the same input produces identical bytes", %{
      root: root
    } do
      seed_mixed_mounts!(root)
      :ok = MountsMd.regenerate(root)
      first = File.read!(mounts_md(root))
      :ok = MountsMd.regenerate(root)
      second = File.read!(mounts_md(root))
      assert first == second
    end
  end

  describe "regenerate/1 — empty workspace" do
    test "no mounts at all still produces a valid, non-empty file", %{root: root} do
      assert :ok = MountsMd.regenerate(root)
      assert File.exists?(mounts_md(root))
      content = File.read!(mounts_md(root))
      assert content != ""
      assert content =~ "Valea"
      refute content =~ "@mounts/"
    end
  end
end
