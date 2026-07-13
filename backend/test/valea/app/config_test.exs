defmodule Valea.App.ConfigTest do
  use ExUnit.Case, async: false

  alias Valea.App.Config

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{dir: dir}
  end

  test "read returns empty defaults when no file exists" do
    assert Config.read() == %{
             "known_workspaces" => [],
             "last_opened" => nil,
             "harness_command" => ["claude-agent-acp"],
             "harness_command_approved" => true
           }
  end

  test "workspaces_dir is under the app dir" do
    assert Config.workspaces_dir() == Path.join(Config.dir(), "workspaces")
  end

  test "record_opened keys by id and sets last_opened to the id" do
    ws = Path.join(Config.workspaces_dir(), "coaching-a2f3")
    File.mkdir_p!(ws)
    :ok = Config.record_opened(%{id: "id-1", name: "Coaching", slug: "coaching", path: ws})

    assert Config.last_opened_id() == "id-1"
    assert %{"id" => "id-1", "name" => "Coaching", "path" => ^ws} = Config.workspace_by_id("id-1")
    assert [%{"id" => "id-1"}] = Config.recent()
  end

  test "record_opened persists and read round-trips", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(%{id: "id-1", name: "Test Workspace", slug: "test-workspace", path: ws})

    assert %{"last_opened" => "id-1", "known_workspaces" => [entry]} = Config.read()
    assert entry["name"] == "Test Workspace"
    assert entry["path"] == ws
  end

  test "record_opened upserts by id (no duplicates)", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(%{id: "id-1", name: "A", slug: "a", path: ws})
    Config.record_opened(%{id: "id-1", name: "A renamed", slug: "a", path: ws})
    assert %{"known_workspaces" => [entry]} = Config.read()
    assert entry["name"] == "A renamed"
  end

  test "recent drops entries whose folder no longer exists" do
    :ok =
      Config.record_opened(%{
        id: "gone",
        name: "Gone",
        slug: "gone",
        path: Path.join(Config.workspaces_dir(), "gone-0000")
      })

    assert Config.recent() == []
    assert Config.workspace_by_id("gone") == nil or match?(%{}, Config.workspace_by_id("gone"))
  end

  test "recent prunes workspaces missing on disk", %{dir: dir} do
    gone = Path.join(dir, "gone")
    File.mkdir_p!(gone)
    Config.record_opened(%{id: "id-1", name: "Gone", slug: "gone", path: gone})
    File.rm_rf!(gone)
    assert Config.recent() == []
  end

  test "clear_last_opened keeps known list", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(%{id: "id-1", name: "A", slug: "a", path: ws})
    Config.clear_last_opened()
    assert %{"last_opened" => nil, "known_workspaces" => [_]} = Config.read()
  end

  test "read tolerates corrupt json (returns defaults, does not raise)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), "{nope")

    assert Config.read() == %{
             "known_workspaces" => [],
             "last_opened" => nil,
             "harness_command" => ["claude-agent-acp"],
             "harness_command_approved" => true
           }
  end

  test "harness_command defaults to claude-agent-acp, implicitly approved" do
    assert Config.harness_command() == ["claude-agent-acp"]
    assert Config.harness_command_approved?() == true
  end

  test "set_harness_command persists and marks approval false when non-default" do
    Config.set_harness_command(["/usr/bin/custom-acp", "--flag"])

    assert Config.harness_command() == ["/usr/bin/custom-acp", "--flag"]
    assert Config.harness_command_approved?() == false
  end

  test "set_harness_command back to the default restores implicit approval" do
    Config.set_harness_command(["/usr/bin/custom-acp"])
    assert Config.harness_command_approved?() == false

    Config.set_harness_command(["claude-agent-acp"])
    assert Config.harness_command_approved?() == true
  end

  test "set_harness_command rejects an empty list" do
    assert_raise FunctionClauseError, fn -> apply(Config, :set_harness_command, [[]]) end
  end
end
