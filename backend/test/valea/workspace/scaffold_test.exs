defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Scaffold

  setup do
    t = Path.join(System.tmp_dir!(), "vsc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(t) end)
    %{target: t}
  end

  defp another_target do
    t = Path.join(System.tmp_dir!(), "vsc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(t) end)
    t
  end

  test "creates the hidden v5 layout with no agent-routing files", %{target: t} do
    :ok = Scaffold.create(t, "Coaching business", "74fa36f2-0000-0000-0000-000000000000")

    assert Scaffold.valid?(t)

    for d <- ~w(config sources queue logs queue/staging queue/processing runtime),
        do: assert(File.dir?(Path.join(t, d)), "missing #{d}")

    refute File.exists?(Path.join(t, "AGENTS.md"))
    refute File.exists?(Path.join(t, "CLAUDE.md"))
    refute File.exists?(Path.join(t, "MOUNTS.md"))
    refute File.dir?(Path.join(t, "mounts"))
    refute File.dir?(Path.join(t, ".claude"))

    yaml = File.read!(Path.join(t, "config/workspace.yaml"))
    assert yaml =~ "version: 5"
    assert yaml =~ "74fa36f2-0000-0000-0000-000000000000"
    assert yaml =~ ~s(name: "Coaching business")
    assert yaml =~ "icms: {}"
  end

  test "creates .gitignore (not the template's un-dotted gitignore)", %{target: t} do
    :ok = Scaffold.create(t, "Acme", "id-1")
    assert File.exists?(Path.join(t, ".gitignore"))
    refute File.exists?(Path.join(t, "gitignore"))
  end

  test "refuses a non-empty target", %{target: t} do
    File.mkdir_p!(t)
    File.write!(Path.join(t, "existing.txt"), "x")
    assert {:error, :target_not_empty} = Scaffold.create(t, "Acme", "id-1")
  end

  test "each scaffold carries the given id, not a minted one", %{target: t} do
    :ok = Scaffold.create(t, "Acme", "fixed-id")
    yaml = File.read!(Path.join(t, "config/workspace.yaml"))
    assert yaml =~ "id: fixed-id"
  end

  test "valid? recognizes a scaffolded v5 workspace and rejects others", %{target: t} do
    :ok = Scaffold.create(t, "Acme", "id-1")
    assert Scaffold.valid?(t)
    refute Scaffold.valid?(System.tmp_dir!())
  end

  test "valid? requires every v5 marker dir, including runtime/", %{target: t} do
    :ok = Scaffold.create(t, "Acme", "id-1")
    File.rm_rf!(Path.join(t, "runtime"))
    refute Scaffold.valid?(t)
  end

  test "inspect_summary reports a valid, empty (no ICMs yet) workspace", %{target: t} do
    :ok = Scaffold.create(t, "Acme", "id-1")
    summary = Scaffold.inspect_summary(t)
    assert summary.valid
    assert summary.icm_pages == 0
    assert summary.workflows == 0
    assert summary.queue_pending == 0
    assert summary.has_audit_log
  end

  test "slugify/1 is unchanged: lowercase, ascii-fold, dashed" do
    assert Scaffold.slugify("Café Löwen & Co.!!") == "cafe-lowen-co"
    assert Scaffold.slugify("!!!") == "mount"
  end

  # Scaffold.create/1 and create/2 are the LEGACY (v4, all-are-mounts)
  # scaffold — still LIVE production code (Valea.Workspace.Manager.create/2,
  # Valea.Workspace.Adopt.create_with_icm/3) until Phase 11 deletes them, so
  # they keep their own regression coverage here, separate from the v5
  # create/3 tests above.
  describe "create/2 (legacy v4 workspace)" do
    test "writes config/workspace.yaml as version 4 with a fresh, valid, non-TEMPLATE uuid id",
         %{target: t} do
      :ok = Scaffold.create(t, "Acme Coaching")

      yaml = File.read!(Path.join(t, "config/workspace.yaml"))
      assert yaml =~ "version: 4"
      assert [id] = Regex.run(~r/^id: ([0-9a-f-]{36})$/m, yaml, capture: :all_but_first)
      refute id == "TEMPLATE"

      # each scaffold mints its own, distinct workspace id
      other = another_target()
      :ok = Scaffold.create(other, "Acme Coaching")
      other_yaml = File.read!(Path.join(other, "config/workspace.yaml"))

      assert [other_id] =
               Regex.run(~r/^id: ([0-9a-f-]{36})$/m, other_yaml, capture: :all_but_first)

      refute other_id == id
    end

    test "produces the legacy layout: root AGENTS.md/CLAUDE.md, a starter mount with its own icm.yaml, and MOUNTS.md",
         %{target: t} do
      :ok = Scaffold.create(t, "Acme Coaching")

      assert File.exists?(Path.join(t, "AGENTS.md"))
      assert File.exists?(Path.join(t, "CLAUDE.md"))
      assert File.exists?(Path.join(t, "MOUNTS.md"))

      mount_dir = Path.join(t, "mounts/acme-coaching")
      assert File.dir?(mount_dir)
      refute File.dir?(Path.join(t, "mounts/starter"))

      assert {:ok, manifest} = Manifest.load(mount_dir)
      assert manifest.name == "Acme Coaching"
      refute manifest.id == "TEMPLATE"
      assert Regex.match?(~r/^[0-9a-f-]{36}$/, manifest.id)
    end

    test "two scaffolds mint DIFFERENT starter-mount icm.yaml ids", %{target: t} do
      :ok = Scaffold.create(t, "Acme Coaching")
      {:ok, manifest} = Manifest.load(Path.join(t, "mounts/acme-coaching"))

      other = another_target()
      :ok = Scaffold.create(other, "Acme Coaching")
      {:ok, other_manifest} = Manifest.load(Path.join(other, "mounts/acme-coaching"))

      refute other_manifest.id == manifest.id
    end

    test "the legacy scaffold still satisfies valid?/1 (it also creates runtime/)", %{target: t} do
      :ok = Scaffold.create(t, "Acme Coaching")
      assert Scaffold.valid?(t)
    end
  end
end
