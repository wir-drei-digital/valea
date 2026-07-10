defmodule Valea.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: false

  alias Valea.Harnesses.ClaudeCode

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

  test "definition names the harness" do
    assert %{id: "claude_code", name: "Claude Code"} = ClaudeCode.definition()
  end

  test "resolves a configured absolute command as-is" do
    cat = System.find_executable("cat")
    Valea.App.Config.set_harness_command([cat, "--extra"])

    assert {:ok, spec} = ClaudeCode.acp_command(%{env: %{"HOME" => "/tmp"}})
    assert spec.cmd == cat
    assert spec.args == ["--extra"]
    assert spec.env["HOME"] == "/tmp"
  after
    Valea.App.Config.set_harness_command(["claude-agent-acp"])
  end

  test "missing executable -> harness_unavailable" do
    Valea.App.Config.set_harness_command(["definitely-not-a-real-binary-xyz"])
    assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{})
  after
    Valea.App.Config.set_harness_command(["claude-agent-acp"])
  end

  test "empty harness_command config -> harness_unavailable, never raises", %{dir: dir} do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config.json"),
      Jason.encode!(%{"harness_command" => [], "harness_command_approved" => true})
    )

    assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{})
  end

  test "a directory as the absolute cmd -> harness_unavailable (not File.exists?)", %{dir: dir} do
    Valea.App.Config.set_harness_command([dir])
    assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{})
  after
    Valea.App.Config.set_harness_command(["claude-agent-acp"])
  end

  test "a relative cmd is rejected even if it happens to resolve" do
    Valea.App.Config.set_harness_command(["./x"])
    assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{})
  after
    Valea.App.Config.set_harness_command(["claude-agent-acp"])
  end
end
