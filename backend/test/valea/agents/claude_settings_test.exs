defmodule Valea.Agents.ClaudeSettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.ClaudeSettings

  setup do
    root = Path.join(System.tmp_dir!(), "vws-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
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
end
