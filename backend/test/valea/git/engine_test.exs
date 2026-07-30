# Wraps the real Cli so a test can see WHICH git verbs a pass actually ran —
# the only way to assert a NEGATIVE (a backed-off pass that never reached the
# network) without timing games.
defmodule Valea.Git.EngineTest.RecordingCli do
  @behaviour Valea.Git.Cli

  @impl true
  def run(repo_root, args, opts) do
    case Application.get_env(:valea, :git_cli_probe) do
      pid when is_pid(pid) -> send(pid, {:git_run, args})
      _absent -> :ok
    end

    # `:git_cli_delay_ms` stretches a pass over a known window, so a test can
    # land a cast on the Engine WHILE its pass task is still running. Applied
    # to the state read every pass begins with.
    delay = Application.get_env(:valea, :git_cli_delay_ms, 0)
    if delay > 0 and match?(["status" | _], args), do: Process.sleep(delay)

    Valea.Git.Cli.run(repo_root, args, opts)
  end
end

# A process sitting exactly where a real agent session would, so
# `Valea.Agents.SessionServer.attach/1` — the Engine's liveness question about
# a recorded conflict session — answers "running" without a whole ACP session.
defmodule Valea.Git.EngineTest.FakeSession do
  use GenServer

  def start_link(id) do
    GenServer.start_link(__MODULE__, :ok,
      name: {:via, Registry, {Valea.Agents.SessionRegistry, id, nil}}
    )
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(:attach, _from, state),
    do: {:reply, {:ok, %{items: [], cursor: 0, busy: false, status: "running"}}, state}
end

defmodule Valea.Git.EngineTest do
  # async: false — the Engine is a singleton (`name: __MODULE__`) and every
  # seam here is application env.
  use ExUnit.Case, async: false

  alias Valea.Git.Engine
  alias Valea.Git.EngineTest.FakeSession
  alias Valea.Git.EngineTest.RecordingCli
  alias Valea.Mounts
  alias Valea.Mounts.Manifest

  if not GitFixtures.git_available?(), do: @moduletag(:skip)

  @gen 7

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "vgit-eng-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    repos = Path.join(base, "repos")
    ws = Path.join(base, "ws")
    File.mkdir_p!(repos)
    File.mkdir_p!(Path.join(ws, "config"))
    on_exit(fn -> File.rm_rf!(base) end)

    fx = GitFixtures.remote_and_clones!(repos)

    # The clone becomes a real ICM, manifest COMMITTED — so the repo starts
    # clean and `dirty` in a status row is always something the test did.
    Manifest.write!(fx.work, %{id: Ecto.UUID.generate(), name: "Work ICM", description: ""})
    GitFixtures.git!(fx.work, ["add", "-A"])
    GitFixtures.git!(fx.work, ["commit", "-m", "icm manifest"])
    GitFixtures.git!(fx.work, ["push", "origin", "main"])

    write_config!(ws, %{"work" => fx.work})

    %{base: base, ws: ws, fx: fx, key: "work"}
  end

  # -- helpers ---------------------------------------------------------------

  defp start_engine!(root, cfg \\ %{activate: true}) do
    Application.put_env(:valea, :git_sync_probe, self())
    Application.put_env(:valea, :git_poll_interval_ms, 3_600_000)
    Application.put_env(:valea, :git_poll_jitter, 0)

    on_exit(fn ->
      Application.delete_env(:valea, :git_sync_probe)
      Application.delete_env(:valea, :git_poll_interval_ms)
      Application.delete_env(:valea, :git_poll_jitter)
    end)

    start_supervised!({Engine, Map.merge(%{root: root, generation: @gen}, cfg)})
  end

  defp await_pass! do
    assert_receive {:git_pass_finished, statuses}, 15_000
    statuses
  end

  # Hand-written config, the same "hand edit" shape `Valea.ICM.WatcherTest`'s
  # `declare_external!/3` writes — no Manager, no VALEA_APP_DIR.
  defp write_config!(ws, mounts) do
    entries =
      mounts
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {name, path} -> ["  #{name}:", "    path: #{inspect(path)}"] end)

    File.write!(
      Path.join(ws, "config/workspace.yaml"),
      Enum.join(["version: 4", "id: #{Ecto.UUID.generate()}", "icms:"] ++ entries, "\n") <> "\n"
    )
  end

  defp head(repo), do: repo |> GitFixtures.git!(["rev-parse", "HEAD"]) |> String.trim()
  defp bare_head(bare), do: bare |> GitFixtures.git!(["rev-parse", "main"]) |> String.trim()

  defp subject(repo, ref),
    do: repo |> GitFixtures.git!(["log", "-1", "--format=%s", ref]) |> String.trim()

  # A repo with a branch but no upstream at all.
  defp lone_repo!(base, name) do
    dir = Path.join(base, name)
    File.mkdir_p!(dir)
    GitFixtures.git!(dir, ["init", "--initial-branch=main", "."])
    GitFixtures.identity!(dir)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})
    GitFixtures.write_commit!(dir, "note.md", "solo", "solo")
    dir
  end

  # A `.git` FILE — a linked worktree or submodule, which `Repo.detect/1`
  # refuses to touch.
  defp linked_worktree_icm!(base, name) do
    dir = Path.join(base, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".git"), "gitdir: /elsewhere\n")
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: ""})
    dir
  end

  defp flush_git_runs do
    receive do
      {:git_run, _args} -> flush_git_runs()
    after
      0 -> :ok
    end
  end

  defp count_fetches(seen \\ 0) do
    receive do
      {:git_run, ["fetch" | _]} -> count_fetches(seen + 1)
      {:git_run, _other} -> count_fetches(seen)
    after
      0 -> seen
    end
  end

  defp count_merges(seen \\ 0) do
    receive do
      {:git_run, ["merge" | _]} -> count_merges(seen + 1)
      {:git_run, _other} -> count_merges(seen)
    after
      0 -> seen
    end
  end

  # -- tests -----------------------------------------------------------------

  test "no engine at all: statuses are empty and callers get :not_running" do
    assert Engine.statuses() == %{}
    assert Engine.sync_now("work") == {:error, :not_running}
    assert Engine.conflict_handoff("work") == {:error, :not_running}
  end

  test "inert until ITS OWN generation is opened", %{ws: ws, key: key} do
    start_engine!(ws, %{})

    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_opened, %{}, @gen + 1})
    refute_receive {:git_pass_finished, _}, 300
    assert Engine.statuses() == %{}

    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_opened, %{}, @gen})
    statuses = await_pass!()

    assert %{^key => row} = statuses
    assert row.state == "ok"
    assert row.mode == "pull"
    assert row.icm_name == "Work ICM"
    assert row.branch == "main"
    assert row.ahead == 0 and row.behind == 0 and row.dirty == false
    assert is_binary(row.last_sync_at)
    # The notice identity Tasks 4/5 key on: level with the remote means the
    # two shas are the same one.
    assert is_binary(row.local_sha)
    assert row.local_sha == row.remote_sha
    assert Engine.statuses() == statuses

    # A closed workspace forgets everything it knew.
    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_closed})
    assert eventually(fn -> Engine.statuses() == %{} end)
  end

  test "pull mode fast-forwards a repo that is behind", %{ws: ws, fx: fx, key: key} do
    start_engine!(ws)
    await_pass!()

    GitFixtures.advance_remote!(fx)
    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    assert %{state: "ok", behind: 0, ahead: 0} = statuses[key]
    assert head(fx.work) == bare_head(fx.bare)
    assert File.exists?(Path.join(fx.work, "remote.md"))
  end

  test "pull mode never pushes", %{ws: ws, fx: fx, key: key} do
    start_engine!(ws)
    await_pass!()

    remote_before = bare_head(fx.bare)
    GitFixtures.advance_local!(fx)

    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    assert %{state: "ok", ahead: 1, behind: 0, mode: "pull"} = statuses[key]
    assert bare_head(fx.bare) == remote_before
  end

  test "full mode commits a dirty tree and pushes it", %{ws: ws, fx: fx, key: key} do
    assert :ok = Mounts.set_git_sync(ws, key, "full")
    start_engine!(ws)
    await_pass!()

    remote_before = bare_head(fx.bare)
    File.write!(Path.join(fx.work, "note.md"), "written by the user")

    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    assert %{state: "ok", mode: "full", dirty: false, ahead: 0, behind: 0} = statuses[key]
    assert bare_head(fx.bare) != remote_before
    assert String.starts_with?(subject(fx.bare, "main"), "valea sync: ")
  end

  test "a diverged repo is HELD — no fetch, no merge, no push", %{ws: ws, fx: fx, key: key} do
    start_engine!(ws)
    await_pass!()

    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    assert %{state: "diverged", ahead: 1, behind: 1} = statuses[key]
    assert statuses[key].local_sha == head(fx.work)
    assert statuses[key].remote_sha == bare_head(fx.bare)
    assert statuses[key].local_sha != statuses[key].remote_sha

    work_before = head(fx.work)
    remote_before = bare_head(fx.bare)

    assert :ok = Engine.sync_now(key)
    held = await_pass!()

    assert held[key].state == "diverged"
    assert head(fx.work) == work_before
    assert bare_head(fx.bare) == remote_before

    # Held means held: the remote moving again does not even get FETCHED, so
    # the counts stay exactly as stale as they were.
    GitFixtures.advance_remote!(fx, "second.md")
    assert :ok = Engine.sync_now(key)
    still_held = await_pass!()

    assert %{state: "diverged", ahead: 1, behind: 1} = still_held[key]
    assert head(fx.work) == work_before
    refute File.exists?(Path.join(fx.work, "second.md"))
  end

  test "uncommitted local edits blocking a fast-forward read as blocked_local", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    start_engine!(ws)
    await_pass!()

    GitFixtures.advance_remote!(fx, "seed.md", "remote seed")
    File.write!(Path.join(fx.work, "seed.md"), "local uncommitted")

    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    assert %{state: "blocked_local", behind: 1, ahead: 0, dirty: true} = statuses[key]
    assert is_binary(statuses[key].last_error)
    assert File.read!(Path.join(fx.work, "seed.md")) == "local uncommitted"
  end

  test "an unfinished merge is reported and touched by nothing", %{ws: ws, fx: fx, key: key} do
    GitFixtures.conflict!(fx)
    work_before = head(fx.work)
    remote_before = bare_head(fx.bare)

    start_engine!(ws)
    statuses = await_pass!()

    assert statuses[key].state == "merge_in_progress"
    assert statuses[key].branch == "main"
    assert head(fx.work) == work_before
    assert bare_head(fx.bare) == remote_before
  end

  # A rebase stopped at a conflict has NO current branch. Classified on
  # `branch` first this reads `detached`, which is not conflict-class, and the
  # repo can never be handed to a resolution session.
  test "a conflicted rebase reads as merge_in_progress and can be handed off", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    GitFixtures.rebase_conflict!(fx)
    work_before = head(fx.work)
    remote_before = bare_head(fx.bare)

    start_engine!(ws)
    statuses = await_pass!()

    assert statuses[key].branch == nil, "fixture must leave HEAD detached mid-rebase"
    assert statuses[key].state == "merge_in_progress"
    assert head(fx.work) == work_before
    assert bare_head(fx.bare) == remote_before

    assert {:ok, %{briefing: briefing}} = Engine.conflict_handoff(key)
    assert briefing =~ "a merge/rebase was left unfinished"
    assert briefing =~ "branch detached"
    assert briefing =~ "clash.md"
  end

  # The failure mode that makes a "behind and dirty ⇒ blocked" guess unusable:
  # anything can move `behind` (a terminal `git fetch`, another tool, the
  # resolution session itself), and almost no dirt actually blocks a
  # fast-forward. Guessing here would hold the repo forever — held repos never
  # fetch, so `behind` could never fall again.
  test "an external fetch plus dirt that clobbers nothing still fast-forwards", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    start_engine!(ws)
    await_pass!()

    GitFixtures.advance_remote!(fx, "remote.md", "remote change")
    # Someone outside Valea fetched: `behind` is already non-zero when the pass
    # starts, with no ff refusal ever having happened.
    GitFixtures.git!(fx.work, ["fetch", "origin"])

    # Dirt the incoming commit does not touch, plus an untracked file.
    File.write!(Path.join(fx.work, "seed.md"), "local notes")
    File.write!(Path.join(fx.work, "editor.tmp"), "junk")

    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    assert %{state: "ok", behind: 0, ahead: 0} = statuses[key]
    assert head(fx.work) == bare_head(fx.bare)
    # The remote's work arrived and the user's edits are untouched.
    assert File.read!(Path.join(fx.work, "remote.md")) == "remote change"
    assert File.read!(Path.join(fx.work, "seed.md")) == "local notes"
    assert File.read!(Path.join(fx.work, "editor.tmp")) == "junk"
    assert statuses[key].dirty == true
  end

  test "full mode commits the user's work even when the repo is behind", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    assert :ok = Mounts.set_git_sync(ws, key, "full")
    start_engine!(ws)
    await_pass!()

    GitFixtures.advance_remote!(fx, "seed.md", "remote seed")
    GitFixtures.git!(fx.work, ["fetch", "origin"])
    File.write!(Path.join(fx.work, "seed.md"), "the user's work")

    remote_before = bare_head(fx.bare)

    assert :ok = Engine.sync_now(key)
    statuses = await_pass!()

    # Full mode's contract: the work becomes a COMMIT rather than sitting
    # uncommitted behind a hold.
    assert String.starts_with?(subject(fx.work, "HEAD"), "valea sync: ")
    assert File.read!(Path.join(fx.work, "seed.md")) == "the user's work"

    # And the result is the self-limiting hold, not a merge Valea authored.
    assert %{state: "diverged", ahead: 1, behind: 1, dirty: false} = statuses[key]
    assert bare_head(fx.bare) == remote_before

    # Held from here on, like any other divergence.
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"
    assert bare_head(fx.bare) == remote_before
  end

  test "blocked_local is held on later passes and self-heals", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    Application.put_env(:valea, :git_cli, RecordingCli)
    Application.put_env(:valea, :git_cli_probe, self())

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_probe)
    end)

    start_engine!(ws)
    await_pass!()

    GitFixtures.advance_remote!(fx, "seed.md", "remote seed")
    File.write!(Path.join(fx.work, "seed.md"), "local uncommitted")
    # Unrelated dirt that blocks nothing, present throughout — the hold must be
    # about the file git actually objected to, not about "the tree is dirty".
    File.write!(Path.join(fx.work, "editor.tmp"), "junk")

    # Discovered the only way it can be: a fast-forward git refused.
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "blocked_local"

    work_before = head(fx.work)
    remote_before = bare_head(fx.bare)
    flush_git_runs()

    # From here on it is HELD — derived locally, so no fetch and no merge run
    # under whoever is resolving it.
    assert :ok = Engine.sync_now(key)
    held = await_pass!()

    assert held[key].state == "blocked_local"
    refute_received {:git_run, ["fetch" | _]}
    refute_received {:git_run, ["merge" | _]}
    refute_received {:git_run, ["push" | _]}
    assert head(fx.work) == work_before
    assert bare_head(fx.bare) == remote_before
    assert File.read!(Path.join(fx.work, "seed.md")) == "local uncommitted"

    # A held row is still handoff-able: the handoff re-derives with the row's
    # own state, so it agrees with the pass instead of calling this "ok".
    assert {:ok, %{briefing: briefing}} = Engine.conflict_handoff(key)
    assert briefing =~ "uncommitted local edits block the fast-forward"
    assert briefing =~ "seed.md"

    # The user puts back ONLY the file git objected to. The unrelated untracked
    # file stays — so the tree is still dirty, and a hold keyed on "dirty" would
    # never let go, forever, because a held repo never fetches.
    File.write!(Path.join(fx.work, "seed.md"), "seed")

    assert :ok = Engine.sync_now(key)
    healed = await_pass!()

    assert %{state: "ok", behind: 0} = healed[key]
    assert head(fx.work) == bare_head(fx.bare)
    # The remote's work arrived, and the harmless dirt is still sitting there.
    assert File.read!(Path.join(fx.work, "seed.md")) == "remote seed"
    assert File.read!(Path.join(fx.work, "editor.tmp")) == "junk"
    assert healed[key].dirty == true
  end

  test "a DIFFERENT obstruction is re-tested and re-refused by git", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    Application.put_env(:valea, :git_cli, RecordingCli)
    Application.put_env(:valea, :git_cli_probe, self())

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_probe)
    end)

    start_engine!(ws)
    await_pass!()

    # The incoming work touches TWO files, so there are two different ways for
    # the local tree to be in its way.
    GitFixtures.advance_remote!(fx, "seed.md", "remote seed")
    GitFixtures.advance_remote!(fx, "other.md", "remote other")

    File.write!(Path.join(fx.work, "seed.md"), "local uncommitted")
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "blocked_local"

    work_before = head(fx.work)

    # Swap which file is in the way: the old obstruction is gone, a new one
    # (an untracked file the incoming commit would create) takes its place.
    File.write!(Path.join(fx.work, "seed.md"), "seed")
    File.write!(Path.join(fx.work, "other.md"), "mine, not the remote's")
    flush_git_runs()

    assert :ok = Engine.sync_now(key)
    retested = await_pass!()

    # The verdict expired with the tree it was about, so git was asked again —
    # exactly once — and refused again.
    assert count_merges() == 1
    assert retested[key].state == "blocked_local"

    # And a refused fast-forward changed nothing.
    assert head(fx.work) == work_before
    assert File.read!(Path.join(fx.work, "other.md")) == "mine, not the remote's"

    # The new verdict is held in its own right: no further network.
    flush_git_runs()
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "blocked_local"
    refute_received {:git_run, ["fetch" | _]}
    refute_received {:git_run, ["merge" | _]}
  end

  test "a flush with nothing to commit does not start a pass", %{ws: ws, key: key} do
    Application.put_env(:valea, :git_commit_quiet_ms, 50)
    on_exit(fn -> Application.delete_env(:valea, :git_commit_quiet_ms) end)

    assert :ok = Mounts.set_git_sync(ws, key, "full")
    start_engine!(ws)
    assert await_pass!()[key].state == "ok"

    # Exactly what a pass's own fetch looks like to the ICM watcher: a write
    # under the ICM (`.git/FETCH_HEAD`) with nothing of the user's in it. If
    # this started a pass, the pass would fetch, and the Engine would trigger
    # itself every debounce window for as long as the workspace is open.
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})
    refute_receive {:git_pass_finished, _}, 1_000
  end

  test "a conflict session recorded mid-pass survives the pass landing", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    Application.put_env(:valea, :git_cli, RecordingCli)

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_delay_ms)
    end)

    start_engine!(ws)
    await_pass!()

    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    start_supervised!({FakeSession, "sess-live"})

    # Every state read now takes ~400ms, so the cast below lands while the pass
    # task is still running — its snapshot was taken before the id existed.
    Application.put_env(:valea, :git_cli_delay_ms, 400)
    assert :ok = Engine.sync_now(key)
    :ok = Engine.record_conflict_session(key, "sess-live")

    statuses = await_pass!()

    assert statuses[key].state == "diverged"
    assert statuses[key].conflict_session_id == "sess-live"
    assert Engine.statuses()[key].conflict_session_id == "sess-live"
  end

  test "off, no_upstream and unsupported rows", %{ws: ws, base: base, fx: fx} do
    solo = lone_repo!(base, "solo")
    linked = linked_worktree_icm!(base, "linked")
    write_config!(ws, %{"work" => fx.work, "solo" => solo, "linked" => linked})
    assert :ok = Mounts.set_git_sync(ws, "work", "off")

    start_engine!(ws)
    statuses = await_pass!()

    assert %{state: "off", mode: "off"} = statuses["work"]
    assert %{state: "no_upstream", branch: "main"} = statuses["solo"]
    assert %{state: "unsupported"} = statuses["linked"]
    assert statuses["linked"].reason =~ "worktree or submodule"
  end

  test "a failed fetch errors and backs off; sync_now overrides it", %{ws: ws, fx: fx, key: key} do
    Application.put_env(:valea, :git_cli, RecordingCli)
    Application.put_env(:valea, :git_cli_probe, self())

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_probe)
    end)

    start_engine!(ws)
    await_pass!()

    # Local facts worth keeping: a commit the remote has not seen, and an
    # uncommitted edit on top of it.
    GitFixtures.advance_local!(fx)
    File.write!(Path.join(fx.work, "scratch.md"), "wip")

    File.rm_rf!(fx.bare)
    assert :ok = Engine.sync_now(key)
    errored = await_pass!()

    assert errored[key].state == "error"
    assert is_binary(errored[key].last_error)

    # An unreachable remote says nothing about the working tree — the row still
    # knows what this repo IS.
    assert %{branch: "main", ahead: 1, behind: 0, dirty: true} = errored[key]
    assert errored[key].local_sha == head(fx.work)

    # A POLL-driven pass while the backoff window is open reports the same
    # error and never touches the network.
    flush_git_runs()
    send(Process.whereis(Engine), :poll)
    backed_off = await_pass!()

    refute_received {:git_run, ["fetch" | _]}
    assert backed_off[key].state == "error"
    assert backed_off[key].last_error == errored[key].last_error
    assert %{branch: "main", ahead: 1, dirty: true} = backed_off[key]

    # An explicit sync_now is the user overriding the backoff.
    flush_git_runs()
    assert :ok = Engine.sync_now(key)
    retried = await_pass!()

    assert_received {:git_run, ["fetch" | _]}
    assert retried[key].state == "error"
  end

  test "a sync_now queued behind a running pass still overrides the backoff", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    Application.put_env(:valea, :git_cli, RecordingCli)
    Application.put_env(:valea, :git_cli_probe, self())

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_probe)
    end)

    start_engine!(ws)
    await_pass!()

    File.rm_rf!(fx.bare)
    flush_git_runs()

    # The second request lands while the first request's pass is still in
    # flight, so it rides `pending_sync` — and must NOT be re-gated by the
    # backoff the in-flight pass is about to arm.
    assert :ok = Engine.sync_now(key)
    assert :ok = Engine.sync_now(key)

    assert await_pass!()[key].state == "error"
    assert await_pass!()[key].state == "error"

    assert count_fetches() == 2
  end

  test "an ICM change debounces into a full-mode commit", %{ws: ws, fx: fx, key: key} do
    Application.put_env(:valea, :git_commit_quiet_ms, 50)
    on_exit(fn -> Application.delete_env(:valea, :git_commit_quiet_ms) end)

    assert :ok = Mounts.set_git_sync(ws, key, "full")
    start_engine!(ws)
    await_pass!()

    File.write!(Path.join(fx.work, "typed.md"), "the user typed this")
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})

    statuses = await_pass!()

    assert %{state: "ok", dirty: false} = statuses[key]
    assert String.starts_with?(subject(fx.work, "HEAD"), "valea sync: ")
  end

  test "conflict handoff briefs, remembers its session, and expires", %{ws: ws, fx: fx, key: key} do
    start_engine!(ws)
    await_pass!()

    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    assert {:ok, handoff} = Engine.conflict_handoff(key)
    assert handoff.existing_session_id == nil
    assert handoff.icm_name == "Work ICM"
    assert handoff.briefing =~ "local: local.md"
    assert handoff.briefing =~ "remote: remote.md"
    assert handoff.briefing =~ ~s(the "Work ICM" ICM)
    assert handoff.briefing =~ "Never force-push"

    assert Engine.conflict_handoff("no-such-mount") == {:error, :not_found}
    assert Engine.sync_now("no-such-mount") == {:error, :not_found}

    :ok = Engine.record_conflict_session(key, "sess-1")
    assert Engine.statuses()[key].conflict_session_id == "sess-1"
    assert {:ok, %{existing_session_id: "sess-1"}} = Engine.conflict_handoff(key)

    # The user (or the session) resolves it by hand, exactly as the briefing
    # asks: merge, then push.
    GitFixtures.git!(fx.work, ["merge", "origin/main", "-m", "merge remote"])
    GitFixtures.git!(fx.work, ["push", "origin", "main"])

    assert :ok = Engine.sync_now(key)
    resolved = await_pass!()

    assert %{state: "ok", conflict_session_id: nil} = resolved[key]
    assert Engine.conflict_handoff(key) == {:error, :no_conflict}
  end

  test "every pass broadcasts on the git topic", %{ws: ws, key: key} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "git")
    start_engine!(ws)

    assert_receive {:git_status_changed, statuses}, 15_000
    assert %{^key => %{state: "ok"}} = statuses

    :ok = Engine.record_conflict_session(key, "sess-9")
    assert_receive {:git_status_changed, %{^key => %{conflict_session_id: "sess-9"}}}, 2_000
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
