# Shared helpers for tests that drive a real agent session end-to-end through
# the fake ACP adapter (test/support/fake_adapter.exs). Used by both the
# SessionServer unit tests and the AgentSessionChannel tests, which need
# slightly different surrounding setup (the channel needs a REAL open
# workspace so `Valea.Workspace.Manager.current/0` resolves for file replay
# and `Valea.Agents.list_sessions/0`), so this stays a plain function module
# rather than an ExUnit.Case `use` macro.
defmodule Valea.AgentCase do
  alias Valea.Workspace.Manager

  @doc "Command spec for the fake ACP adapter test double, for a given scenario name."
  def fake_cmd(scenario) do
    elixir = System.find_executable("elixir")
    jason = Path.expand("_build/test/lib/jason/ebin")
    script = Path.expand("test/support/fake_adapter.exs")
    [elixir, "-pa", jason, script, scenario]
  end

  @doc """
  Points the harness at the fake adapter for `scenario`, then starts a session
  rooted at `workspace` with `extra` merged over sane test defaults.
  """
  def start_session(workspace, scenario, extra \\ %{}) do
    Valea.App.Config.set_harness_command(fake_cmd(scenario))

    Valea.Agents.start_session(
      Map.merge(
        %{
          kind: "chat",
          title: "Test",
          workspace: workspace,
          generation: 1,
          run: nil,
          initial_prompt: nil,
          on_turn_end: nil,
          policy_ctx: %{workspace: workspace, session_kind: "chat", write_paths: []}
        },
        extra
      )
    )
  end

  @doc """
  Isolated `VALEA_APP_DIR` + a freshly created, opened workspace — for tests
  that need `Valea.Workspace.Manager.current/0` to resolve (channel join
  replay, `Valea.Agents.list_sessions/0`). Registers `on_exit` cleanup and
  returns the opened workspace map (`%{path: ..., ...}`).
  """
  def open_workspace!(name \\ "W") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    ExUnit.Callbacks.on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), name)
    ws
  end

  @doc """
  Terminates the LIVE `SessionServer` process for `id` (not merely its
  adapter subprocess, unlike `SessionServer.stop/1`), so a subsequent
  `SessionServer.attach/1` returns `{:error, :not_running}` and callers fall
  through to file replay. Synchronous: blocks until the process is gone.
  """
  def kill_session(id) do
    case GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}}) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
