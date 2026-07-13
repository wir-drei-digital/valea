defmodule Valea.ICM.SearchTest do
  use ExUnit.Case, async: false

  alias Valea.ICM.Search
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path}
  end

  test "AND semantics across title and body, ranked title-first", %{workspace: ws} do
    File.write!(
      Path.join(ws, "mounts/primary/Offers/Retainer.md"),
      "# Retainer\n\nMonthly coaching retainer.\n"
    )

    File.write!(
      Path.join(ws, "mounts/primary/Clients/Note.md"),
      "# Note\n\nDiscussed a retainer with Julia.\n"
    )

    {:ok, %{results: results}} = Search.search(ws, "retainer")
    paths = Enum.map(results, & &1.path)
    assert Enum.at(paths, 0) == "mounts/primary/Offers/Retainer.md"
    assert "mounts/primary/Clients/Note.md" in paths

    {:ok, %{results: both}} = Search.search(ws, "retainer julia")
    assert Enum.map(both, & &1.path) == ["mounts/primary/Clients/Note.md"]
  end

  test "workflow contracts are searchable; snippet carries the match", %{workspace: ws} do
    {:ok, %{results: results}} = Search.search(ws, "classify")
    assert Enum.any?(results, &String.contains?(&1.path, "Workflows/"))
    hit = Enum.find(results, &String.contains?(&1.path, "Workflows/"))
    assert String.downcase(hit.snippet) =~ "classify"
    assert hit.terms == ["classify"]
  end

  test "disabled mounts are excluded", %{workspace: ws} do
    :ok = Valea.Mounts.set_enabled("primary", false)
    {:ok, %{results: results}} = Search.search(ws, "coaching")
    assert results == []
    :ok = Valea.Mounts.set_enabled("primary", true)
  end

  test "a mount over budget is skipped and reported", %{workspace: ws} do
    {:ok, [mount]} = Valea.Mounts.enabled()

    {:ok, %{results: [], skipped: ["primary"]}} =
      Search.search(ws, "coaching", mounts: [mount], timeout_ms: 0)
  end

  test "empty and whitespace queries return nothing", %{workspace: ws} do
    assert {:ok, %{results: [], skipped: []}} = Search.search(ws, "   ")
  end

  test "regex metacharacters are literal text", %{workspace: ws} do
    File.write!(
      Path.join(ws, "mounts/primary/Offers/Weird.md"),
      "# Weird\n\nprice (150) [draft]\n"
    )

    {:ok, %{results: results}} = Search.search(ws, "(150)")
    assert Enum.map(results, & &1.path) == ["mounts/primary/Offers/Weird.md"]
  end
end
