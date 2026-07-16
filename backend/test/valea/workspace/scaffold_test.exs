defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Valea.Workspace.Scaffold

  setup do
    t = Path.join(System.tmp_dir!(), "vsc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(t) end)
    %{target: t}
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

  test "slugify/1 is unchanged: lowercase, ascii-fold, dashed" do
    assert Scaffold.slugify("Café Löwen & Co.!!") == "cafe-lowen-co"
    assert Scaffold.slugify("!!!") == "mount"
  end
end
