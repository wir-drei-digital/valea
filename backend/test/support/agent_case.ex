# Shared helpers for tests that drive a real agent session end-to-end through
# the fake ACP adapter (test/support/fake_adapter.exs). Used by both the
# SessionServer unit tests and the AgentSessionChannel tests, which need
# slightly different surrounding setup (the channel needs a REAL open
# workspace so `Valea.Workspace.Manager.current/0` resolves for file replay
# and `Valea.Agents.list_sessions/0`), so this stays a plain function module
# rather than an ExUnit.Case `use` macro.
defmodule Valea.AgentCase do
  alias Valea.Agents.SessionScope
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  @doc """
  Command spec for the fake ACP adapter test double, for a given scenario
  name. `extra_args` are appended after the scenario name (e.g. a mounted
  external ICM's resolved root, for a scenario that needs to address a path
  outside the workspace — see `"permission_risk_tier"` in
  `test/support/fake_adapter.exs`).
  """
  def fake_cmd(scenario, extra_args \\ []) do
    elixir = System.find_executable("elixir")
    jason = Path.expand("_build/test/lib/jason/ebin")
    script = Path.expand("test/support/fake_adapter.exs")
    [elixir, "-pa", jason, script, scenario | extra_args]
  end

  @doc """
  Points the harness at the fake adapter for `scenario`, resolves a
  `Valea.Agents.SessionScope` for `workspace`'s primary ICM (Task 5.4 — a
  session now launches with cwd = the primary ICM's own root, never the
  workspace), then starts a session with `extra` merged over sane test
  defaults.

  `workspace` MUST be the CURRENTLY OPEN workspace
  (`Valea.Workspace.Manager.current/0`) — `SessionScope.resolve/1` resolves
  against the Manager's own tracked state (current workspace + generation),
  not the `workspace` argument directly, so every caller needs an
  `open_workspace!/1`-opened (or equivalent) workspace, not a bare tmp dir.

  `extra` may carry, popped off before the rest is merged into the
  session-start map:

    * `:harness_args` — extra CLI args for the fake adapter (see
      `fake_cmd/2`).
    * `:mount_key` — the primary ICM's mount key (defaults to the first
      `Valea.Mounts.enabled/1` mount — a test that only ever mounts one ICM,
      the common case via `mount_test_icm!/2`, never needs to pass this).
    * `:kind` — the scope's session kind (default `"chat"`).
    * `:read_paths` / `:write_paths` / `:write_roots` — the exact grants
      `SessionScope.resolve/1` folds into the scope verbatim (a workflow-kind
      scope's per-run grants; empty by default).

  Propagates `{:error, :icm_unavailable}` / `{:error, :workspace_changed}`
  from `SessionScope.resolve/1` the same way `Valea.Agents.start_session/1`
  itself propagates its own errors — a test asserting a start FAILURE (e.g.
  a disabled primary mount) can match on the return value directly.
  """
  def start_session(workspace, scenario, extra \\ %{}) do
    {harness_args, extra} = Map.pop(extra, :harness_args, [])
    {mount_key, extra} = Map.pop(extra, :mount_key, nil)
    {kind, extra} = Map.pop(extra, :kind, "chat")
    {read_paths, extra} = Map.pop(extra, :read_paths, [])
    {write_paths, extra} = Map.pop(extra, :write_paths, [])
    {write_roots, extra} = Map.pop(extra, :write_roots, [])

    Valea.App.Config.set_harness_command(fake_cmd(scenario, harness_args))

    id = "test-" <> Ecto.UUID.generate()
    mount_key = mount_key || primary_mount_key!(workspace)

    with {:ok, scope} <-
           SessionScope.resolve(%{
             kind: kind,
             mount_key: mount_key,
             generation: Manager.generation(),
             session_id: id,
             read_paths: read_paths,
             write_paths: write_paths,
             write_roots: write_roots
           }) do
      Valea.Agents.start_session(
        Map.merge(
          %{
            id: id,
            kind: kind,
            title: "Test",
            scope: scope,
            run: nil,
            initial_prompt: nil,
            on_turn_end: nil
          },
          extra
        )
      )
    end
  end

  # The first enabled (non-degraded) mount in `workspace`, sorted by mount
  # key (`Mounts.list/1`'s own order) — the common single-mount test setup's
  # implicit primary, so a test that mounted exactly one ICM via
  # `mount_test_icm!/2` never needs to name it. A test with more than one
  # mount, or that needs a SPECIFIC one, passes `mount_key:` explicitly.
  defp primary_mount_key!(workspace) do
    case Mounts.enabled(workspace) do
      [%{name: name} | _] ->
        name

      [] ->
        raise "Valea.AgentCase.start_session/3: no enabled mount in #{workspace} — " <>
                "call mount_test_icm!/2 in the test's setup first, or pass mount_key: explicitly"
    end
  end

  @doc """
  Isolated `VALEA_APP_DIR` + a freshly created, opened v5 (id-based, hidden
  under `Valea.App.Config.workspaces_dir/0`) workspace — for tests that
  need `Valea.Workspace.Manager.current/0` to resolve (channel join replay,
  `Valea.Agents.list_sessions/0`). Registers `on_exit` cleanup and returns
  the opened workspace map (`%{path: ..., ...}`).

  Every caller of this helper must be `async: false` (a hard requirement:
  the isolation below mutates the `VALEA_APP_DIR` process env var, which is
  GLOBAL to the VM — safe only because ExUnit never runs an `async: false`
  test concurrently with anything else).
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

    {:ok, ws} = Manager.create(name)
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

  @doc """
  Creates a real EXTERNAL ICM directory (format-2 `icm.yaml`, plus
  caller-specified content) in the test tmp area and mounts it into
  `workspace` via `Valea.Mounts.mount/2` — the post-3.2 replacement for the
  legacy v4 scaffold's seeded `mounts/<slug>` starter mount, which
  `Valea.Mounts.list/1` no longer discovers (config truth, `icms:`-only —
  see that module's moduledoc). Every mounted ICM is now BY-REFERENCE, so
  every consumer (`Valea.Workflows`, `Valea.ICM`, `RiskTier`,
  `MemoryProposal.check_target/2`, ...) addresses its content by the
  RESOLVED ABSOLUTE path, never a workspace-relative `mounts/<name>/...`
  string — build paths against the returned `root`, e.g.
  `Path.join(icm.root, "Workflows/My Workflow.md")`, not a hand-written
  `"mounts/<name>/..."` literal.

  Returns `%{mount_key:, id:, root:}` — `root` is the REALPATH-resolved
  absolute path (mirrors what `Valea.Mounts.list/1`/`mount_for/2` report,
  e.g. macOS's `/var` -> `/private/var`), so callers get the exact value
  every other Mounts-aware module would compute.

  `opts`:

    * `:name` — the ICM's display name, also the seed for the derived
      mount key (default `"Primary"`).
    * `:id` — a specific manifest UUID (default a fresh one).
    * `:pages` — `%{"relative/path.md" => content}`, written into the ICM
      root BEFORE mounting — e.g. `%{"Workflows/My Workflow.md" => "..."}`
      for a Runner test, or a target page for a Queue/memory-update test.
      Intermediate directories are created as needed. Defaults to `%{}` —
      callers needing more than the bare `icm.yaml` must pass this; this
      helper does NOT force the full `priv/icm_template/` tree onto every
      test ICM (keep fixtures minimal by default; use
      `Valea.Mounts.create/3` directly in the rare test that wants the
      real template).
    * `:agents_md` — override `AGENTS.md` content (default a one-line
      stub).
    * `:enabled` — mount, then immediately `Valea.Mounts.set_enabled/3` to
      this value if `false` (default `true` — no extra call).

  Registers `on_exit` cleanup of the ICM's own tmp directory (independent
  of the workspace's own cleanup, so it runs even for a workspace that
  isn't itself a fresh `on_exit`-cleaned tmp dir).
  """
  def mount_test_icm!(workspace, opts \\ []) do
    name = Keyword.get(opts, :name, "Primary")
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    pages = Keyword.get(opts, :pages, %{})
    agents_md = Keyword.get(opts, :agents_md, "# #{name}\n")
    enabled = Keyword.get(opts, :enabled, true)

    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-icm-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(
      Path.join(dir, "icm.yaml"),
      Valea.Mounts.Manifest.render(%{id: id, name: name, description: ""})
    )

    File.write!(Path.join(dir, "AGENTS.md"), agents_md)

    for {rel, content} <- pages do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    case Mounts.mount(workspace, dir) do
      {:ok, %{mount_key: mount_key, id: ^id}} ->
        unless enabled, do: :ok = Mounts.set_enabled(workspace, mount_key, false)
        %{mount_key: mount_key, id: id, root: Mounts.mount_by_key(workspace, mount_key).root}

      {:error, reason} ->
        raise "mount_test_icm! failed to mount #{dir} into #{workspace}: #{inspect(reason)}"
    end
  end
end
