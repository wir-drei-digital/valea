defmodule Valea.ICMTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager
  alias Valea.ICM

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, _} = Manager.create(Path.join(dir, "workspaces"), "W")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  test "tree lists seeded folders with counts" do
    {:ok, tree} = ICM.tree()
    names = Enum.map(tree, & &1.name)
    assert "Offers" in names
    assert "Tone & Voice" in names
    offers = Enum.find(tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.page_count == 2
    assert Enum.any?(offers.children, &(&1.name == "Founder Coaching Package"))
  end

  test "page reads content with title and uri" do
    {:ok, page} = ICM.page("Offers/Founder Coaching Package.md")
    assert page.title == "Founder Coaching Package"
    assert page.uri == "icm://Offers/Founder Coaching Package.md"
    assert page.content =~ "## Best fit"
  end

  test "page rejects escape attempts" do
    assert {:error, :outside_workspace} = ICM.page("../logs/audit.jsonl")
    assert {:error, :outside_workspace} = ICM.page("Offers/../../secrets/x")
  end

  test "page returns not_found for a missing page" do
    assert {:error, :not_found} = ICM.page("Offers/Nope.md")
  end

  test "errors without a workspace" do
    Manager.close()
    assert {:error, :no_workspace} = ICM.tree()
    assert {:error, :no_workspace} = ICM.page("Offers/Founder Coaching Package.md")
  end
end
