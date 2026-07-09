defmodule Valea.App.ConfigTest do
  use ExUnit.Case, async: false

  alias Valea.App.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    on_exit(fn -> System.delete_env("VALEA_APP_DIR") end)
    %{dir: dir}
  end

  test "read returns empty defaults when no file exists" do
    assert Config.read() == %{"known_workspaces" => [], "last_opened" => nil}
  end

  test "record_opened persists and read round-trips", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(ws, "Test Workspace")

    assert %{"last_opened" => ^ws, "known_workspaces" => [entry]} = Config.read()
    assert entry["name"] == "Test Workspace"
    assert entry["path"] == ws
  end

  test "record_opened upserts by path (no duplicates)", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(ws, "A")
    Config.record_opened(ws, "A renamed")
    assert %{"known_workspaces" => [entry]} = Config.read()
    assert entry["name"] == "A renamed"
  end

  test "recent prunes workspaces missing on disk", %{dir: dir} do
    gone = Path.join(dir, "gone")
    File.mkdir_p!(gone)
    Config.record_opened(gone, "Gone")
    File.rm_rf!(gone)
    assert Config.recent() == []
  end

  test "clear_last_opened keeps known list", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(ws, "A")
    Config.clear_last_opened()
    assert %{"last_opened" => nil, "known_workspaces" => [_]} = Config.read()
  end

  test "read tolerates corrupt json (returns defaults, does not raise)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), "{nope")
    assert Config.read() == %{"known_workspaces" => [], "last_opened" => nil}
  end
end
