defmodule Valea.Agents.DoctorTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.Doctor
  alias Valea.PlatformFixtures

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

  # Both lanes need these probes (spec B5), so every fixture ships a `sh` and
  # a `cmd` body — see `Valea.PlatformFixtures`. Only the ASSERTIONS that
  # cannot cross platforms (`pgrep -f`, `exec -a`) are tagged.
  defp script!(dir, name, unix_body, windows_body),
    do: PlatformFixtures.script!(dir, name, unix_body, windows_body)

  # Answers both `--version` (adapter check) and `--cli auth status` (auth
  # check) successfully, regardless of which one is invoked.
  defp ok_adapter!(dir) do
    script!(
      dir,
      "acp-ok",
      """
      case "$1" in
        --version) echo "0.58.1" ;;
        --cli) exit 0 ;;
      esac
      """,
      """
      @echo off\r
      if "%1"=="--version" echo 0.58.1\r
      exit /b 0\r
      """
    )
  end

  defp adapter_fails!(dir) do
    script!(
      dir,
      "acp-adapter-fail",
      """
      case "$1" in
        --version) exit 1 ;;
        --cli) exit 0 ;;
      esac
      """,
      """
      @echo off\r
      if "%1"=="--version" exit /b 1\r
      exit /b 0\r
      """
    )
  end

  defp auth_fails!(dir) do
    script!(
      dir,
      "acp-auth-fail",
      """
      case "$1" in
        --version) echo "0.58.1" ;;
        --cli) exit 1 ;;
      esac
      """,
      """
      @echo off\r
      if "%1"=="--version" (echo 0.58.1& exit /b 0)\r
      exit /b 1\r
      """
    )
  end

  # `exec -a marker` renames the sleeper's argv[0] so the orphan-check test
  # can find it precisely with `pgrep -f marker`, even though the process
  # is really just `sleep`. The pid doesn't change — `exec` replaces the
  # current script process's image in place — so it's still the exact
  # process the doctor's timeout path must kill.
  #
  # The windows body sleeps with `ping`, not `timeout`: `timeout` refuses to
  # run at all when stdin is a pipe, which it always is under the spawn shim.
  defp auth_hangs!(dir, marker) do
    script!(
      dir,
      "acp-auth-hang",
      """
      case "$1" in
        --version) echo "0.58.1" ;;
        --cli) exec -a "#{marker}" sleep 10 ;;
      esac
      """,
      """
      @echo off\r
      if "%1"=="--version" (echo 0.58.1& exit /b 0)\r
      ping -n 11 127.0.0.1 >nul\r
      """
    )
  end

  defp pgrep_count(marker) do
    case System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> length()
      {_output, _no_matches} -> 0
    end
  end

  # Settle briefly and re-check — belt-and-suspenders around the OS's own
  # process-table bookkeeping. `:exec.stop/1` (used by Doctor's timeout
  # path) is documented as synchronous, so this should already be 0 on the
  # first check; the retries just guard against CI flakiness.
  defp assert_no_process_matching(marker) do
    result =
      Enum.reduce_while(1..10, pgrep_count(marker), fn _, count ->
        if count == 0 do
          {:halt, 0}
        else
          Process.sleep(50)
          {:cont, pgrep_count(marker)}
        end
      end)

    assert result == 0,
           "expected no orphaned process matching #{inspect(marker)}, " <>
             "but pgrep -f found #{result}"
  end

  defp fake_node!(dir, version_line) do
    script!(
      dir,
      "node-fake",
      "echo \"#{version_line}\"\n",
      "@echo off\r\necho #{version_line}\r\n"
    )
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

  test "node version with no minor/patch (bare 'v22') -> parses major and passes", %{dir: dir} do
    node = fake_node!(dir, "v22")
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])

    assert {:ok, %{checks: checks}} = Doctor.run(%{node: node})

    assert %{"id" => "node", "status" => "ok", "remedy" => nil} = check(checks, "node")
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

  @tag :unix_only
  @tag timeout: 20_000
  test "auth hangs past the 5s timeout -> unknown, not failed, and the hung OS process is killed",
       %{dir: dir} do
    node = fake_node!(dir, "v22.3.0")
    marker = "valea-doctor-test-sleeper-#{System.unique_integer([:positive])}"

    on_exit(fn -> System.cmd("pkill", ["-9", "-f", marker], stderr_to_stdout: true) end)

    Valea.App.Config.set_harness_command([auth_hangs!(dir, marker)])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{"status" => "ok"} = check(checks, "adapter")

    assert %{"status" => "unknown", "remedy" => nil, "detail" => detail} = check(checks, "auth")
    assert detail =~ "could not be determined"

    # The whole point of routing the probe through the process adapter: the
    # sleeping child must not survive as an orphan after Doctor.run/1
    # returns, or repeated doctor runs against a hung adapter would pile up
    # zombie `sleep` processes. On unix that promise is erlexec's process-
    # group kill; `pgrep -f` is how you ask.
    assert_no_process_matching(marker)
  end

  # The windows twin: same probe, same 5s timeout, and the same "unknown, not
  # failed" verdict — the orphan half of the assertion is `tasklist`'s job,
  # and the adapter's Job Object is what makes it true (spec B2).
  @tag :windows_only
  @tag timeout: 20_000
  test "auth hangs past the 5s timeout -> unknown, and no sleeper survives", %{dir: dir} do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command([auth_hangs!(dir, "unused-on-windows")])

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(%{node: node})

    assert %{"status" => "ok"} = check(checks, "adapter")
    assert %{"status" => "unknown", "remedy" => nil, "detail" => detail} = check(checks, "auth")
    assert detail =~ "could not be determined"

    Process.sleep(500)
    {out, _} = System.cmd("tasklist", ["/fi", "imagename eq ping.exe"], stderr_to_stdout: true)
    refute out =~ "ping.exe"
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

  # The runtime's messages are untagged and addressed to whoever called
  # `start/2`, so before each probe got its OWN process a straggler from a
  # timed-out probe — exactly the two messages below — was collected as the
  # NEXT check's result. Planting them up front is the cheap synthetic of that
  # race: with per-probe task isolation they stay in this process's mailbox,
  # unread, and every check still reports the truth.
  test "a stray runtime message in the caller's mailbox is not read as a probe's result", %{
    dir: dir
  } do
    node = fake_node!(dir, "v22.3.0")
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])

    send(self(), {:runtime_exit, 99})
    send(self(), {:runtime_output, "straggler"})

    assert {:ok, %{checks: checks, ok: true}} = Doctor.run(%{node: node})
    assert %{"status" => "ok"} = check(checks, "node")
    assert %{"status" => "ok"} = check(checks, "adapter")
    assert %{"status" => "ok"} = check(checks, "auth")

    assert_received {:runtime_exit, 99}
    assert_received {:runtime_output, "straggler"}
  end

  test "run/0 delegates to run/1 with no overrides", %{dir: dir} do
    Valea.App.Config.set_harness_command([ok_adapter!(dir)])

    assert {:ok, %{checks: checks, ok: _}} = Doctor.run()
    assert length(checks) == 3
  end
end
