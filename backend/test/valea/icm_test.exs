defmodule Valea.ICMTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM

  defp write_mount!(ws_path, name, title) do
    dir = Path.join([ws_path, "mounts", name])
    File.mkdir_p!(dir)
    Manifest.write!(dir, %{id: "id-" <> name, name: title, description: ""})
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    # A fresh scaffold (T8) mints its own real mount from the template's rich
    # seed content (Offers/, Workflows/, etc.) at `mounts/<slug-of-name>` —
    # naming the workspace "Primary" lands that mount at exactly
    # `mounts/primary`, the name/title this whole suite asserts against, with
    # no separate copy/seed step needed.
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path}
  end

  test "tree lists seeded folders with counts, grouped by mount" do
    {:ok, [mount]} = ICM.tree()
    assert mount.mount == "primary"
    assert mount.title == "Primary"
    assert mount.root_rel == "mounts/primary"

    names = Enum.map(mount.tree, & &1.name)
    assert "Offers" in names
    assert "Tone & Voice" in names
    offers = Enum.find(mount.tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.path == "mounts/primary/Offers"
    assert offers.page_count == 2
    child = Enum.find(offers.children, &(&1.name == "Founder Coaching Package"))
    assert child
    assert child.path == "mounts/primary/Offers/Founder Coaching Package.md"
    assert child.uri == "icm://mounts/primary/Offers/Founder Coaching Package.md"
  end

  test "page reads content with title and uri" do
    {:ok, page} = ICM.page("mounts/primary/Offers/Founder Coaching Package.md")
    assert page.title == "Founder Coaching Package"
    assert page.uri == "icm://mounts/primary/Offers/Founder Coaching Package.md"
    assert page.content =~ "## Best fit"
  end

  test "page rejects escape attempts" do
    assert {:error, :outside_workspace} = ICM.page("../logs/audit.jsonl")
    assert {:error, :outside_workspace} = ICM.page("Offers/../../secrets/x")
    assert {:error, :outside_workspace} = ICM.page("mounts/primary/../../logs/audit.jsonl")
  end

  test "page returns not_found for a missing page" do
    assert {:error, :not_found} = ICM.page("mounts/primary/Offers/Nope.md")
  end

  test "errors without a workspace" do
    Manager.close()
    assert {:error, :no_workspace} = ICM.tree()
    assert {:error, :no_workspace} = ICM.page("mounts/primary/Offers/Founder Coaching Package.md")
  end

  describe "multiple mounts" do
    setup %{ws: ws} do
      write_mount!(ws, "a", "Mount A")
      File.write!(Path.join([ws, "mounts", "a", "Notes.md"]), "# A Note\n")

      write_mount!(ws, "b", "Mount B")
      File.write!(Path.join([ws, "mounts", "b", "Secret.md"]), "# B Secret\n")
      :ok = Mounts.set_enabled("b", false)

      :ok
    end

    test "tree/0 returns one entry per ENABLED mount, with workspace-relative node paths" do
      {:ok, mounts} = ICM.tree()
      assert Enum.map(mounts, & &1.mount) |> Enum.sort() == ["a", "primary"]
      refute Enum.any?(mounts, &(&1.mount == "b"))

      a = Enum.find(mounts, &(&1.mount == "a"))
      assert a.title == "Mount A"
      assert a.root_rel == "mounts/a"
      assert [%{path: "mounts/a/Notes.md", type: :page, uri: "icm://mounts/a/Notes.md"}] = a.tree
    end

    test "page reads a specific mount's file by its full workspace-relative path" do
      assert {:ok, page} = ICM.page("mounts/a/Notes.md")
      assert page.content == "# A Note\n"
      assert page.uri == "icm://mounts/a/Notes.md"
    end

    test "page reads a DISABLED mount's page fine — enabled-gating is a read_roots/agent concern, not the editor's" do
      assert {:ok, page} = ICM.page("mounts/b/Secret.md")
      assert page.content == "# B Secret\n"
    end

    test "a `..` escape cannot cross from one mount into another" do
      assert {:error, :outside_workspace} = ICM.page("mounts/a/../b/Secret.md")
    end

    test "create/rename/delete operate within the resolving mount's own containment", %{ws: ws} do
      assert {:ok, %{path: "mounts/a/New.md"}} = ICM.create_page("mounts/a", "New")
      assert {:ok, %{path: "mounts/a/Sub"}} = ICM.create_folder("mounts/a", "Sub")

      assert {:ok, %{path: "mounts/a/Renamed.md"}} = ICM.rename("mounts/a/New.md", "Renamed")

      assert {:ok, %{deleted: true}} = ICM.delete("mounts/a/Renamed.md")
      refute File.exists?(Path.join(ws, "mounts/a/Renamed.md"))

      # Escaping mount a's own root while creating is denied, even though
      # mount "b" is a real, discovered mount.
      assert {:error, :outside_workspace} = ICM.create_page("mounts/a/../b", "Intruder")
    end
  end
end
