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

# Every network verb fails, with the argv still reported to the probe — the
# rig for asserting that a failed PUSH paces itself the way a failed fetch
# does. `push.output` carries the latin-1 bytes a real server's error message
# can contain.
defmodule Valea.Git.EngineTest.FailingPushCli do
  @behaviour Valea.Git.Cli

  @impl true
  def run(root, args, opts) do
    case Application.get_env(:valea, :git_cli_probe) do
      pid when is_pid(pid) -> send(pid, {:git_run, args})
      _absent -> :ok
    end

    case args do
      ["push" | _] ->
        {:ok,
         %{output: <<"fatal: Authentication failed for 'origin' ", 0xFF, 0xFE, "\n">>, exit: 128}}

      _local_or_fetch ->
        Valea.Git.Cli.run(root, args, opts)
    end
  end
end

# git output is BYTES. This one puts non-UTF-8 into the two places that reach
# the JSON wire: a fetch error (the status row's `last_error`) and a commit
# subject (the conflict briefing's `initial_prompt`).
defmodule Valea.Git.EngineTest.RawBytesCli do
  @behaviour Valea.Git.Cli

  @impl true
  def run(root, args, opts) do
    if Application.get_env(:valea, :git_raw_fetch_fails, false) and match?(["fetch" | _], args) do
      {:ok, %{output: <<"fatal: could not read from remote ", 0xFF, 0xFE, "\n">>, exit: 128}}
    else
      corrupt(args, Valea.Git.Cli.run(root, args, opts))
    end
  end

  defp corrupt(["log" | _], {:ok, %{exit: 0, output: out}}),
    do: {:ok, %{exit: 0, output: <<"caf", 0xE9, " ">> <> out}}

  defp corrupt(_other, result), do: result
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
  alias Valea.Git.EngineTest.FailingPushCli
  alias Valea.Git.EngineTest.FakeSession
  alias Valea.Git.EngineTest.RawBytesCli
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

  # The two facts the ".valea/ → .gitignore" card keys on. They ride the
  # status row (rather than an RPC of their own) because the row is already
  # pushed on every pass, and the card must retire the moment the fix lands.
  test "rows carry the .valea ignore/track facts", %{ws: ws, fx: fx, key: key} do
    File.mkdir_p!(Path.join(fx.work, ".valea"))
    File.write!(Path.join(fx.work, ".valea/briefing.md"), "valea's own")

    start_engine!(ws)
    assert %{valea_ignored: false, valea_tracked: false} = await_pass!()[key]

    GitFixtures.git!(fx.work, ["add", "-f", ".valea"])
    assert :ok = Engine.sync_now(key)
    assert %{valea_tracked: true} = await_pass!()[key]

    GitFixtures.git!(fx.work, ["rm", "-r", "-q", "--cached", ".valea"])
    File.write!(Path.join(fx.work, ".gitignore"), ".valea/\n")
    assert :ok = Engine.sync_now(key)
    assert %{valea_ignored: true, valea_tracked: false} = await_pass!()[key]
  end

  # `off` means Valea leaves the repository alone — including asking git two
  # questions about it. `nil` is "not asked", and the card only ever appears
  # for a `false`.
  test "an off-mode repo is asked nothing about .valea", %{ws: ws, fx: fx, key: key} do
    File.mkdir_p!(Path.join(fx.work, ".valea"))
    File.write!(Path.join(fx.work, ".valea/briefing.md"), "valea's own")
    assert :ok = Mounts.set_git_sync(ws, key, "off")

    start_engine!(ws)

    assert %{state: "off", valea_ignored: nil, valea_tracked: nil} = await_pass!()[key]
  end

  # The other half of `Repo.commit_all/3`'s pathspec: the offer's staged
  # `rm --cached` is the user's consented untracking, and a full-mode pass
  # has to carry it into a commit rather than leaving it staged forever.
  test "a full-mode pass commits the offer's staged removal of .valea", %{
    ws: ws,
    fx: fx,
    key: key
  } do
    File.mkdir_p!(Path.join(fx.work, ".valea"))
    File.write!(Path.join(fx.work, ".valea/briefing.md"), "valea's own")
    GitFixtures.git!(fx.work, ["add", "-f", ".valea"])
    GitFixtures.git!(fx.work, ["commit", "-m", "user committed .valea"])
    GitFixtures.git!(fx.work, ["push", "origin", "main"])

    assert :ok = Mounts.set_git_sync(ws, key, "full")

    # Exactly what `add_valea_gitignore` leaves behind.
    File.write!(Path.join(fx.work, ".gitignore"), ".valea/\n")
    GitFixtures.git!(fx.work, ["rm", "-r", "-q", "--cached", ".valea"])

    start_engine!(ws)
    assert %{state: "ok", dirty: false} = await_pass!()[key]

    assert GitFixtures.git!(fx.work, ["ls-files", "--", ".valea"]) |> String.trim() == ""
    # Untracked, never deleted.
    assert File.exists?(Path.join(fx.work, ".valea/briefing.md"))
    # And the ignore line the same pass committed is in the tree it pushed.
    assert GitFixtures.git!(fx.bare, ["show", "main:.gitignore"]) =~ ".valea/"
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

  # -- conflict slots ----------------------------------------------------------

  # The reservation that makes "resolve" safe to double-click: the decision
  # lives in this loop, so it is settled before any caller spends the hundreds
  # of milliseconds a session start costs.
  test "a claim reserves the conflict slot, and a rival caller is told whose it is", ctx do
    %{ws: ws, fx: fx, key: key} = ctx

    start_engine!(ws)
    await_pass!()
    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    assert :ok = Engine.claim_conflict_session(key, "sess-a")
    # Visible immediately — the button must stop offering "resolve" before
    # the session it refers to has even started.
    assert Engine.statuses()[key].conflict_session_id == "sess-a"

    assert Engine.claim_conflict_session(key, "sess-b") ==
             {:error, {:already_claimed, "sess-a"}}

    # Re-claiming what you already hold is not a conflict with yourself.
    assert :ok = Engine.claim_conflict_session(key, "sess-a")

    assert :ok = Engine.release_conflict_session(key, "sess-a")
    assert Engine.statuses()[key].conflict_session_id == nil
    assert :ok = Engine.claim_conflict_session(key, "sess-b")

    assert Engine.claim_conflict_session("no-such-mount", "sess-x") == {:error, :not_found}
  end

  test "a claimant that dies before starting its session gives the slot back", ctx do
    %{ws: ws, fx: fx, key: key} = ctx

    start_engine!(ws)
    await_pass!()
    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    parent = self()

    claimant =
      spawn(fn ->
        send(parent, {:claimed, Engine.claim_conflict_session(key, "sess-orphan")})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, :ok}, 5_000
    assert Engine.statuses()[key].conflict_session_id == "sess-orphan"

    send(claimant, :stop)

    # Nothing else would ever clear it: no session was started, so no
    # liveness check has anything to find, and the repo would offer to open a
    # session that does not exist forever.
    assert eventually(fn -> Engine.statuses()[key].conflict_session_id == nil end)
  end

  test "a recorded session that is gone can be claimed over", ctx do
    %{ws: ws, fx: fx, key: key} = ctx

    start_engine!(ws)
    await_pass!()
    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    # No process behind it — the resolution session crashed, or the workspace
    # was reopened. A repo whose slot could not be reclaimed would be
    # permanently unresolvable.
    :ok = Engine.record_conflict_session(key, "sess-gone")
    assert Engine.statuses()[key].conflict_session_id == "sess-gone"

    assert :ok = Engine.claim_conflict_session(key, "sess-fresh")
    assert Engine.statuses()[key].conflict_session_id == "sess-fresh"
  end

  # The regression these two pin: a pass's snapshot carrying a STALE recorded
  # id (a session that died and has not been swept yet — the sweep only runs
  # at the end of a pass) used to survive the pass landing, because the
  # restore step only filled in a NIL. The stale id was then blanked for being
  # dead, throwing away the newer slot the loop had accepted meanwhile — and
  # the next click started a rival agent over the same conflicted tree while
  # the first one was alive.
  #
  # Both preconditions are ordinary: a pass spans the whole multi-repo network
  # loop, so "the user clicked resolve during one" is the common case, not the
  # rare one.
  defp diverged_with_stale_recorded_id!(ctx) do
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

    :ok = Engine.record_conflict_session(key, "sess-dead")
    assert Engine.statuses()[key].conflict_session_id == "sess-dead"

    # Every state read now takes ~400 ms, so what follows lands while the pass
    # task is still running — with "sess-dead" in the snapshot it took.
    Application.put_env(:valea, :git_cli_delay_ms, 400)
    assert :ok = Engine.sync_now(key)
    key
  end

  test "a CLAIM landing mid-pass survives a snapshot that carried a stale recorded id", ctx do
    key = diverged_with_stale_recorded_id!(ctx)

    assert :ok = Engine.claim_conflict_session(key, "sess-claimed")

    assert await_pass!()[key].conflict_session_id == "sess-claimed"
    assert Engine.statuses()[key].conflict_session_id == "sess-claimed"

    # The whole point: the slot is still this claimant's after the pass.
    assert Engine.claim_conflict_session(key, "sess-rival") ==
             {:error, {:already_claimed, "sess-claimed"}}
  end

  test "a SESSION recorded mid-pass survives a snapshot that carried a stale recorded id", ctx do
    key = diverged_with_stale_recorded_id!(ctx)

    start_supervised!({FakeSession, "sess-live"})
    :ok = Engine.record_conflict_session(key, "sess-live")

    assert await_pass!()[key].conflict_session_id == "sess-live"
    assert Engine.statuses()[key].conflict_session_id == "sess-live"

    assert Engine.claim_conflict_session(key, "sess-rival") ==
             {:error, {:already_claimed, "sess-live"}}
  end

  test "a pass keeps a PENDING claim, and drops a recorded session that is gone", ctx do
    %{ws: ws, fx: fx, key: key} = ctx

    start_engine!(ws)
    await_pass!()
    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    # A claim whose session is still starting has no `SessionServer` to find.
    # Blanking it in the post-pass sweep would re-open the double-start
    # window the claim exists to close.
    assert :ok = Engine.claim_conflict_session(key, "sess-starting")
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].conflict_session_id == "sess-starting"

    # A RECORDED one is governed by its session's liveness, and that session
    # is gone.
    :ok = Engine.record_conflict_session(key, "sess-dead")
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].conflict_session_id == nil
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

  # A push is the other network verb, and the spec paces network failures. A
  # `nil` retry entry here CLEARED the ladder instead, so a repo that can
  # never push — no credentials in the packaged app's environment, a protected
  # branch — retried at full rate on every poll forever.
  test "a failed push errors and backs off, exactly as a failed fetch does", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    Application.put_env(:valea, :git_cli, FailingPushCli)
    Application.put_env(:valea, :git_cli_probe, self())

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_probe)
    end)

    assert :ok = Mounts.set_git_sync(ws, key, "full")
    start_engine!(ws)
    await_pass!()

    GitFixtures.advance_local!(fx)
    assert :ok = Engine.sync_now(key)
    errored = await_pass!()

    assert errored[key].state == "error"
    assert errored[key].last_error =~ "Authentication failed"
    assert %{ahead: 1, behind: 0, branch: "main"} = errored[key]

    # The backoff is armed: a POLL-driven pass reports the same error over
    # freshly-read local facts and never reaches the network.
    flush_git_runs()
    send(Process.whereis(Engine), :poll)
    backed_off = await_pass!()

    refute_received {:git_run, ["fetch" | _]}
    refute_received {:git_run, ["push" | _]}
    assert backed_off[key].state == "error"
    assert backed_off[key].last_error == errored[key].last_error

    # And `Sync now` is still the way past it.
    flush_git_runs()
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "error"
    assert_received {:git_run, ["push" | _]}
  end

  # git emits the BYTES it was given. A latin-1 error message on a status row
  # used to make `Jason` raise inside the channel's socket process — which the
  # client then rejoins, hitting the same row again: a rejoin loop lasting as
  # long as the error does.
  test "a non-UTF-8 git error round-trips as valid UTF-8 on the status row", ctx do
    %{ws: ws, key: key} = ctx
    Application.put_env(:valea, :git_cli, RawBytesCli)
    Application.put_env(:valea, :git_raw_fetch_fails, true)

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_raw_fetch_fails)
    end)

    start_engine!(ws)
    statuses = await_pass!()

    assert statuses[key].state == "error"
    assert String.valid?(statuses[key].last_error)
    assert statuses[key].last_error =~ "could not read from remote"
    assert statuses[key].last_error =~ <<0xFFFD::utf8>>

    # The property that actually matters: every published row encodes.
    assert is_binary(Jason.encode!(Engine.public_rows(statuses)))
  end

  test "a briefing composed from non-UTF-8 commit subjects is valid UTF-8", ctx do
    %{ws: ws, fx: fx, key: key} = ctx
    Application.put_env(:valea, :git_cli, RawBytesCli)
    on_exit(fn -> Application.delete_env(:valea, :git_cli) end)

    start_engine!(ws)
    await_pass!()

    GitFixtures.diverge!(fx)
    assert :ok = Engine.sync_now(key)
    assert await_pass!()[key].state == "diverged"

    assert {:ok, %{briefing: briefing}} = Engine.conflict_handoff(key)
    assert String.valid?(briefing)
    assert briefing =~ <<0xFFFD::utf8>>
    assert briefing =~ "local: local.md"
    # It is the whole handoff payload that gets JSON-encoded on the RPC reply.
    assert is_binary(Jason.encode!(%{"initial_prompt" => briefing}))
  end

  # `deactivate/1` forgets every row, and a pass still in flight when the
  # workspace closed describes repos this Engine no longer speaks for.
  test "a workspace close clears the rows and discards a pass that lands after it", ctx do
    %{ws: ws, key: key} = ctx
    Application.put_env(:valea, :git_cli, RecordingCli)

    on_exit(fn ->
      Application.delete_env(:valea, :git_cli)
      Application.delete_env(:valea, :git_cli_delay_ms)
    end)

    Phoenix.PubSub.subscribe(Valea.PubSub, "git")
    start_engine!(ws)
    assert await_pass!()[key].state == "ok"
    assert_receive {:git_status_changed, %{^key => _}}, 5_000

    # Every state read now takes ~400 ms, so the close below lands while the
    # pass task is still running.
    Application.put_env(:valea, :git_cli_delay_ms, 400)
    assert :ok = Engine.sync_now(key)
    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_closed})

    assert eventually(fn -> Engine.statuses() == %{} end)

    # The in-flight pass finishes into a closed Engine: no probe, no
    # broadcast, and above all no re-installed rows from the old workspace.
    refute_receive {:git_pass_finished, _}, 3_000
    refute_receive {:git_status_changed, _}, 100
    assert Engine.statuses() == %{}
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
