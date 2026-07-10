defmodule Valea.Agents.DoctorTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.Doctor

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{dir: dir}
  end

  # -- fake executables ----------------------------------------------------

  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Answers both `--version` (adapter check) and `--cli auth status` (auth
  # check) successfully, regardless of which one is invoked.
  defp ok_adapter!(dir) do
    script!(dir, "acp-ok", """
    case "$1" in
      --version) echo "0.58.1" ;;
      --cli) exit 0 ;;
    esac
    """)
  end

  defp adapter_fails!(dir) do
    script!(dir, "acp-adapter-fail", """
    case "$1" in
      --version) exit 1 ;;
      --cli) exit 0 ;;
    esac
    """)
  end

  defp auth_fails!(dir) do
    script!(dir, "acp-auth-fail", """
    case "$1" in
      --version) echo "0.58.1" ;;
      --cli) exit 1 ;;
    esac
    """)
  end

  defp auth_hangs!(dir) do
    script!(dir, "acp-auth-hang", """
    case "$1" in
      --version) echo "0.58.1" ;;
      --cli) sleep 10 ;;
    esac
    """)
  end

  defp fake_node!(dir, version_line) do
    script!(dir, "node-fake", "echo \"#{version_line}\"\n")
  end

  defp check(checks, id), do: Enum.find(checks, &(&1["id"] == id))

  # -- tests -----------------------------------------------------------------

  test "all checks ok -> ok: true", %{dir: dir} do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])

    assert {:ok, %{checks: checks, ok: true}} = Doctor.run(%{node: node})

    assert %{"id" => "node", "status" => "ok", "remedy" => nil} = check(checks, "node")
    assert %{"id" => "adapter", "status" => "ok", "remedy" => nil} = check(checks, "adapter")
    assert %{"id" => "auth", "status" => "ok", "remedy" => nil} = check(checks, "auth")
  end

  test "node older than 22 -> failed with the node remedy, ok flips false", %{dir: dir} do
    node = fake_node!(dir, "v18.0.0")
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{"status" => "failed", "remedy" => "Install Node 22 or newer (https://nodejs.org)"} =
             check(checks, "node")
  end

  test "node override pointing at a missing executable -> failed, no crash", %{dir: dir} do
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])
    missing = Path.join(dir, "no-such-node-binary")

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: missing})

    assert %{"status" => "failed", "remedy" => "Install Node 22 or newer (https://nodejs.org)"} =
             check(checks, "node")
  end

  test "adapter --version failing -> adapter failed, auth unaffected", %{dir: dir} do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command([adapter_fails!(dir)])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{
             "status" => "failed",
             "remedy" => "npm install -g @agentclientprotocol/claude-agent-acp"
           } = check(checks, "adapter")

    assert %{"status" => "ok"} = check(checks, "auth")
  end

  test "auth exit 1 -> failed with the auth remedy", %{dir: dir} do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command([auth_fails!(dir)])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{"status" => "ok"} = check(checks, "adapter")

    assert %{
             "status" => "failed",
             "remedy" => "claude-agent-acp --cli auth login --claudeai"
           } = check(checks, "auth")
  end

  @tag timeout: 20_000
  test "auth hangs past the 5s timeout -> unknown, not failed", %{dir: dir} do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command([auth_hangs!(dir)])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{"status" => "ok"} = check(checks, "adapter")

    assert %{"status" => "unknown", "remedy" => nil, "detail" => detail} = check(checks, "auth")
    assert detail =~ "could not be determined"
  end

  test "adapter unresolvable -> adapter failed, auth is an honest unknown (not failed)", %{
    dir: dir
  } do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command(["definitely-not-a-real-binary-xyz"])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{"status" => "failed"} = check(checks, "adapter")
    assert %{"status" => "unknown", "remedy" => nil} = check(checks, "auth")
  end

  test "run/0 delegates to run/1 with no overrides", %{dir: dir} do
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])

    assert {:ok, %{checks: checks, ok: _}} = Doctor.run()
    assert length(checks) == 3
  end
end
