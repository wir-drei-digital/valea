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

  describe "launch/2" do
    defp launch_scope(tmp) do
      icm = Path.join(tmp, "icm")
      related = Path.join(tmp, "related")
      File.mkdir_p!(icm)
      File.mkdir_p!(related)

      %{
        workspace: %{id: "ws", root: Path.join(tmp, "ws"), name: "W", generation: 1},
        primary_icm: %{mount_key: "coaching", id: "icm-1", root: icm, manifest: nil},
        related_icms: [
          %{
            mount_key: "legal",
            id: "icm-2",
            root: related,
            entrypoint: "CONTEXT.md",
            manifest: nil
          }
        ],
        cwd: icm,
        read_paths: [],
        write_paths: [],
        write_roots: [],
        managed_settings: nil,
        managed_context: Path.join([tmp, "ws", "runtime", "sessions", "s1", "context.md"]),
        kind: "chat"
      }
    end

    test "materializes context, conveys managed_settings in-memory, never writes .claude/ into the ICM" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "vcc-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      scope = launch_scope(tmp)

      assert {:ok, directives} = ClaudeCode.launch(scope, Path.dirname(scope.managed_context))

      assert directives.cwd == scope.cwd
      assert directives.context_path == scope.managed_context
      assert File.exists?(directives.context_path)

      assert Enum.any?(scope.related_icms, fn r -> r.root in directives.additional_roots end)

      posture = Jason.decode!(directives.managed_settings)
      perms = posture["permissions"]

      for glob <- [
            "Read(#{scope.workspace.root}/logs/**)",
            "Read(#{scope.workspace.root}/config/**)",
            "Read(#{scope.workspace.root}/secrets/**)",
            "Read(#{scope.workspace.root}/runtime/**)",
            "Read(#{scope.workspace.root}/.git/**)"
          ] do
        assert glob in perms["deny"]
      end

      assert "Write" in perms["ask"]
      assert "Bash" in perms["ask"]

      refute File.dir?(Path.join(scope.primary_icm.root, ".claude"))
      on_exit(fn -> File.rm_rf!(tmp) end)
    end
  end
end
