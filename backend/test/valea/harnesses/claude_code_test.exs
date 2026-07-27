defmodule Valea.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: false

  alias Valea.Harnesses.ClaudeCode
  alias Valea.PlatformFixtures

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
    exe = PlatformFixtures.host_executable!()
    Valea.App.Config.set_harness_command([exe, "--extra"])

    assert {:ok, spec} = ClaudeCode.acp_command(%{env: %{"HOME" => "/tmp"}})
    assert spec.cmd == exe
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

  # windows-support spec B3. `:platform` is a TEST-ONLY override of the
  # command-RESOLUTION strategy, so windows resolution is provable on any
  # host; the absoluteness/regular-file gate always asks the real host,
  # because what it gates is a real host path.
  describe "windows command resolution" do
    setup %{dir: dir} do
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      previous_path = System.get_env("PATH")
      previous_appdata = System.get_env("APPDATA")
      previous_profile = System.get_env("USERPROFILE")
      # PATH is REPLACED, not prepended: a developer machine with the real
      # adapter installed would otherwise resolve it and hide every fallback
      # these tests exist to exercise.
      System.put_env("PATH", bin)
      System.delete_env("APPDATA")
      System.delete_env("USERPROFILE")

      on_exit(fn ->
        System.put_env("PATH", previous_path)
        restore("APPDATA", previous_appdata)
        restore("USERPROFILE", previous_profile)
        Valea.App.Config.set_harness_command(["claude-agent-acp"])
      end)

      %{bin: bin}
    end

    defp restore(key, nil), do: System.delete_env(key)
    defp restore(key, value), do: System.put_env(key, value)

    defp executable!(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
      File.chmod!(path, 0o755)
      path
    end

    test "a bare name resolves through PATHEXT when the extensionless file does not exist", %{
      bin: bin
    } do
      probe = executable!(Path.join(bin, "probe.cmd"))
      Valea.App.Config.set_harness_command(["probe"])

      assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{platform: :unix})
      assert {:ok, spec} = ClaudeCode.acp_command(%{platform: :windows})
      assert spec.cmd == probe
    end

    test "PATHEXT's own order is honoured when it is set", %{bin: bin} do
      executable!(Path.join(bin, "probe.cmd"))
      com = executable!(Path.join(bin, "probe.com"))

      previous = System.get_env("PATHEXT")
      System.put_env("PATHEXT", ".COM;.EXE;.CMD")
      on_exit(fn -> restore("PATHEXT", previous) end)

      Valea.App.Config.set_harness_command(["probe"])

      assert {:ok, %{cmd: ^com}} = ClaudeCode.acp_command(%{platform: :windows})
    end

    test "an unresolvable bare name falls back to %APPDATA%\\npm\\<cmd>.cmd", %{dir: dir} do
      appdata = Path.join(dir, "AppData")
      npm = executable!(Path.join([appdata, "npm", "claude-agent-acp.cmd"]))
      System.put_env("APPDATA", appdata)

      assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{platform: :unix})
      assert {:ok, %{cmd: ^npm}} = ClaudeCode.acp_command(%{platform: :windows})
    end

    test "then %USERPROFILE%\\.local\\bin\\<cmd>.exe, then the .cmd there", %{dir: dir} do
      profile = Path.join(dir, "Users/tester")
      local_cmd = executable!(Path.join([profile, ".local", "bin", "claude-agent-acp.cmd"]))
      System.put_env("USERPROFILE", profile)

      assert {:ok, %{cmd: ^local_cmd}} = ClaudeCode.acp_command(%{platform: :windows})

      local_exe = executable!(Path.join([profile, ".local", "bin", "claude-agent-acp.exe"]))
      assert {:ok, %{cmd: ^local_exe}} = ClaudeCode.acp_command(%{platform: :windows})
    end

    # `claude.exe` is the interactive CLI, NOT the ACP adapter: resolving it
    # would spawn an executable that does not speak the protocol. Candidates
    # are derived from the CONFIGURED name, never from a hardcoded basename.
    test "install-location candidates derive from the configured name only", %{dir: dir} do
      appdata = Path.join(dir, "AppData")
      executable!(Path.join([appdata, "npm", "claude.cmd"]))
      System.put_env("APPDATA", appdata)

      assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{platform: :windows})

      renamed = executable!(Path.join([appdata, "npm", "my-acp.cmd"]))
      Valea.App.Config.set_harness_command(["my-acp"])
      assert {:ok, %{cmd: ^renamed}} = ClaudeCode.acp_command(%{platform: :windows})
    end

    test "a configured PATH-ish name is never probed against install locations", %{dir: dir} do
      appdata = Path.join(dir, "AppData")
      executable!(Path.join([appdata, "npm", "claude-agent-acp.cmd"]))
      System.put_env("APPDATA", appdata)

      Valea.App.Config.set_harness_command(["./claude-agent-acp"])
      assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{platform: :windows})
    end
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
