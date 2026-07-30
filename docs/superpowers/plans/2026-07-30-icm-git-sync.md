# ICM Git Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-ICM git state + safe auto-sync (fetch/ff, opt-in commit+push) with conflict notices whose one-click button starts an agent session carrying a composed briefing as the first user message.

**Architecture:** A per-workspace singleton `Valea.Git.Engine` (Mail.Engine shape: boots inert, activates on its own generation's `{:workspace_opened, …}` broadcast, jittered 5-minute passes, one linked pass-task at a time) shells out via `Valea.Git.Cli` on `ProcessRuntime`. All state is derived from the repos each pass — no new durable files, no notice storage: cockpit/UI read live statuses. Conflict handoff reuses `create_agent_session`'s internals (`SessionScope.resolve` + `Agents.start_session` with `initial_prompt`), following the `revise_mail_draft` routing shape.

**Tech Stack:** Elixir/Phoenix + Ash (generic `:map` actions, ash_typescript codegen), Phoenix.PubSub → `WorkspaceEventsChannel`, SvelteKit 5 (`$state` stores), system `git` binary, ExUnit + vitest.

**Spec:** `docs/superpowers/specs/2026-07-30-icm-git-sync-design.md` — read it first; it pins mode semantics (`full | pull | off`, default `pull`), pass order, "held means held", notice classes, briefing contract, doctor items, and out-of-scope list.

## Global Constraints

- **Never `System.cmd` in `lib/`** — spawn through `Valea.Agents.ProcessRuntime` so timeouts kill the whole OS process tree (rule stated at `backend/lib/valea/agents/doctor.ex:192-195`). `System.cmd` in tests is fine.
- **Valea never merges (non-ff), rebases, or force-pushes. Held means held**: a repo in `diverged`/`merge_in_progress` state gets local status reads only — no fetch, no commit, no push — until a pass re-derives clean state.
- **ash_typescript falsy-field rule** (canonical: `backend/lib/valea/api/mail.ex` moduledoc): top-level booleans in `:map` action returns use STRING keys (`%{"saved" => true}`); array items are exempt, so repo-status maps ride inside arrays untyped (`{:array, :map}`).
- **Every mutating action takes `generation` and calls `Manager.check_generation/1` first** (pattern: `backend/lib/valea/api/icms.ex:253-272`).
- **Doctor checks** are string-keyed maps `%{"id","label","status","detail","remedy"}`, status strictly `"ok" | "failed" | "unknown"` (`backend/lib/valea/mounts/doctor.ex:457-476`).
- **Engine/watcher tests are `async: false`** (tmp dirs + app-env seams). App-env seams follow `Application.get_env(:valea, key, default)` + `on_exit` cleanup.
- **Channel pushes**: git uses snake_case string keys via the channel's existing `stringify/1` (the `mail_status` precedent, `backend/lib/valea_web/channels/workspace_events_channel.ex:41-43`).
- **Codegen**: after any Api change run `just codegen` (from repo root); generated file is `frontend/src/lib/api/ash_rpc.ts`. Frontend has NO prettier — never run it.
- Backend formatting runs via the project's mix-format hook automatically; don't hand-format.
- Test gates per task: named test files pass, then `cd backend && mix test` green before commit. Frontend tasks: `cd frontend && npm run test` + `npm run check`.
- End commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Git commands run with `GIT_TERMINAL_PROMPT=0` and NO `GIT_SSH_COMMAND` override (respect user ssh config; hangs are killed by the command timeout).

---

### Task 1: `Valea.Git.Cli` + `Valea.Git.Repo` + git test fixtures

**Files:**
- Create: `backend/lib/valea/git/cli.ex`
- Create: `backend/lib/valea/git/repo.ex`
- Create: `backend/test/support/git_fixtures.ex`
- Test: `backend/test/valea/git/repo_test.exs`

**Interfaces:**
- Consumes: `Valea.Agents.ProcessRuntime.start/2` + runtime messages `{:runtime_output, bin} | {:runtime_stderr, bin} | {:runtime_exit, code|nil}` (see `backend/lib/valea/agents/process_adapter.ex:53-62` and the private trio at `backend/lib/valea/agents/doctor.ex:197-255` — copy its Task-isolation rationale). `Valea.Agents.Env.minimal/0` (shape as used by `backend/lib/valea/schedules/command_run.ex`).
- Produces (later tasks rely on these exact names):
  - `Valea.Git.Cli.run(repo_root :: String.t(), args :: [String.t()], opts :: keyword()) :: {:ok, %{output: String.t(), exit: non_neg_integer()}} | {:error, :timeout | :git_not_found}` — `opts[:timeout_ms]` (default 15_000).
  - `Valea.Git.Cli` also defines `@callback run(String.t(), [String.t()], keyword()) :: …` so test stubs can `@behaviour Valea.Git.Cli`.
  - `Valea.Git.Repo.detect(root) :: :repo | {:unsupported, String.t()} | :none`
  - `Valea.Git.Repo.read_state(root, cli) :: {:ok, state()} | {:error, term()}` where `state() :: %{branch: String.t() | nil, upstream: String.t() | nil, dirty: boolean(), conflicted: boolean(), in_progress: :merge | :rebase | :cherry_pick | nil, ahead: non_neg_integer(), behind: non_neg_integer(), local_sha: String.t() | nil, remote_sha: String.t() | nil}`
  - `Valea.Git.Repo.fetch(root, cli) :: :ok | {:error, {:fetch_failed, String.t()} | term()}`
  - `Valea.Git.Repo.commit_all(root, message, cli) :: :ok | {:error, {:commit_failed, String.t()}}` (nothing-to-commit is `:ok`)
  - `Valea.Git.Repo.ff_merge(root, cli) :: :ok | {:error, {:ff_failed, String.t()}}`
  - `Valea.Git.Repo.push(root, cli) :: :ok | {:error, {:push_rejected, String.t()} | {:push_failed, String.t()}}`
  - `Valea.Git.Repo.log_subjects(root, range :: String.t(), cap :: pos_integer(), cli) :: [String.t()]` (e.g. range `"@{u}..HEAD"`)
  - `Valea.Git.Repo.changed_files(root, cap, cli) :: [String.t()]` (porcelain paths, conflicted first)
  - `GitFixtures` helpers (below).

- [ ] **Step 1: Write the fixtures module** — `backend/test/support/git_fixtures.ex`. Every git call goes through one private `git!/3` using `System.cmd` (tests only) with isolated config:

```elixir
defmodule GitFixtures do
  @moduledoc """
  Builds throwaway git topologies for git-engine tests: a bare "remote" plus
  clones that can be pushed independently to fabricate ahead / behind /
  diverged / dirty / conflicted states. Test-only; uses System.cmd directly.
  """

  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "t@example.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "t@example.com"}
  ]

  def git_available?, do: System.find_executable("git") != nil

  def git!(cwd, args) do
    {out, 0} = System.cmd("git", ["-C", cwd | args], env: @env, stderr_to_stdout: true)
    out
  end

  @doc "Returns %{bare: path, work: path, other: path} — two clones of one bare remote, main branch, one seed commit."
  def remote_and_clones!(dir) do
    bare = Path.join(dir, "remote.git")
    work = Path.join(dir, "work")
    other = Path.join(dir, "other")
    File.mkdir_p!(bare)
    git!(bare, ["init", "--bare", "--initial-branch=main", "."])
    git!(dir, ["clone", bare, work])
    write_commit!(work, "seed.md", "seed", "seed")
    git!(work, ["push", "-u", "origin", "main"])
    git!(dir, ["clone", bare, other])
    git!(other, ["checkout", "main"])
    git!(other, ["branch", "--set-upstream-to=origin/main", "main"])
    %{bare: bare, work: work, other: other}
  end

  def write_commit!(repo, rel, content, msg) do
    path = Path.join(repo, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", msg])
  end

  @doc "Advance the remote from `other` so `work` is behind by one commit touching `rel`."
  def advance_remote!(%{other: other}, rel \\ "remote.md", content \\ "remote change") do
    write_commit!(other, rel, content, "remote: #{rel}")
    git!(other, ["push", "origin", "main"])
  end

  @doc "Commit locally in `work` without pushing — work becomes ahead."
  def advance_local!(%{work: work}, rel \\ "local.md", content \\ "local change") do
    write_commit!(work, rel, content, "local: #{rel}")
  end

  @doc "Both sides move on DIFFERENT files — diverged, mergeable."
  def diverge!(fx) do
    advance_local!(fx, "local.md")
    advance_remote!(fx, "remote.md")
  end

  @doc "Leave `work` mid-merge with conflict markers (same file both sides)."
  def conflict!(%{work: work} = fx) do
    write_commit!(work, "clash.md", "local version", "local clash")
    advance_remote!(fx, "clash.md", "remote version")
    git!(work, ["fetch", "origin"])
    {_out, _code} =
      System.cmd("git", ["-C", work, "merge", "origin/main"], env: @env, stderr_to_stdout: true)
    :ok
  end
end
```

- [ ] **Step 2: Write the failing Repo tests** — `backend/test/valea/git/repo_test.exs`. `async: false`; skip the whole module when git is absent:

```elixir
defmodule Valea.Git.RepoTest do
  use ExUnit.Case, async: false

  alias Valea.Git.{Cli, Repo}

  if not GitFixtures.git_available?(), do: @moduletag(:skip)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vgit-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, fx: GitFixtures.remote_and_clones!(dir)}
  end

  test "detect: repo root, non-repo, .git file", %{dir: dir, fx: fx} do
    assert Repo.detect(fx.work) == :repo
    plain = Path.join(dir, "plain")
    File.mkdir_p!(plain)
    assert Repo.detect(plain) == :none
    linked = Path.join(dir, "linked")
    File.mkdir_p!(linked)
    File.write!(Path.join(linked, ".git"), "gitdir: /elsewhere\n")
    assert {:unsupported, reason} = Repo.detect(linked)
    assert reason =~ "worktree or submodule"
  end

  test "detect: mount inside a repo but not at its root is unsupported", %{fx: fx} do
    nested = Path.join(fx.work, "docs")
    File.mkdir_p!(nested)
    assert {:unsupported, reason} = Repo.detect(nested)
    assert reason =~ "root is outside"
  end

  test "read_state: clean in-sync repo", %{fx: fx} do
    assert {:ok, s} = Repo.read_state(fx.work, Cli)
    assert %{branch: "main", upstream: "origin/main", dirty: false, conflicted: false} = s
    assert s.in_progress == nil and s.ahead == 0 and s.behind == 0
    assert is_binary(s.local_sha) and is_binary(s.remote_sha)
  end

  test "read_state: ahead / behind / diverged / dirty", %{fx: fx} do
    GitFixtures.advance_local!(fx)
    assert {:ok, %{ahead: 1, behind: 0}} = Repo.read_state(fx.work, Cli)
    GitFixtures.advance_remote!(fx)
    Repo.fetch(fx.work, Cli)
    assert {:ok, %{ahead: 1, behind: 1}} = Repo.read_state(fx.work, Cli)
    File.write!(Path.join(fx.work, "scratch.md"), "wip")
    assert {:ok, %{dirty: true}} = Repo.read_state(fx.work, Cli)
  end

  test "read_state: mid-merge conflict", %{fx: fx} do
    GitFixtures.conflict!(fx)
    assert {:ok, s} = Repo.read_state(fx.work, Cli)
    assert s.in_progress == :merge and s.conflicted == true
    assert "clash.md" in Repo.changed_files(fx.work, 20, Cli)
  end

  test "commit_all / ff_merge / push round-trip", %{fx: fx} do
    File.write!(Path.join(fx.work, "note.md"), "hello")
    assert :ok = Repo.commit_all(fx.work, "valea sync: test", Cli)
    assert :ok = Repo.commit_all(fx.work, "valea sync: empty", Cli)
    assert :ok = Repo.push(fx.work, Cli)
    GitFixtures.advance_remote!(fx)
    assert :ok = Repo.fetch(fx.work, Cli)
    assert :ok = Repo.ff_merge(fx.work, Cli)
    assert {:ok, %{ahead: 0, behind: 0}} = Repo.read_state(fx.work, Cli)
  end

  test "ff_merge fails cleanly when a dirty file would be clobbered", %{fx: fx} do
    GitFixtures.advance_remote!(fx, "seed.md", "remote edit")
    assert :ok = Repo.fetch(fx.work, Cli)
    File.write!(Path.join(fx.work, "seed.md"), "local edit uncommitted")
    assert {:error, {:ff_failed, out}} = Repo.ff_merge(fx.work, Cli)
    assert out != ""
    assert File.read!(Path.join(fx.work, "seed.md")) == "local edit uncommitted"
  end

  test "log_subjects caps and orders", %{fx: fx} do
    GitFixtures.advance_local!(fx, "a.md")
    GitFixtures.advance_local!(fx, "b.md")
    assert ["local: b.md", "local: a.md"] = Repo.log_subjects(fx.work, "@{u}..HEAD", 10, Cli)
    assert [_one] = Repo.log_subjects(fx.work, "@{u}..HEAD", 1, Cli)
  end

  test "fetch against a vanished remote reports fetch_failed", %{fx: fx} do
    File.rm_rf!(fx.bare)
    assert {:error, {:fetch_failed, _out}} = Repo.fetch(fx.work, Cli)
  end
end
```

- [ ] **Step 3: Run to verify failure** — `cd backend && mix test test/valea/git/repo_test.exs`. Expected: compile error (`Valea.Git.Repo` undefined).

- [ ] **Step 4: Implement `Valea.Git.Cli`** — modeled on `Valea.Agents.Doctor`'s private `run_cmd/spawn_and_await/probe` trio (`backend/lib/valea/agents/doctor.ex:197-255`); read that file first and keep its Task-per-invocation isolation and kill-grace handling:

```elixir
defmodule Valea.Git.Cli do
  @moduledoc """
  Runs git through Valea.Agents.ProcessRuntime — never System.cmd — so a
  timeout guarantees the OS process tree is gone. Each invocation runs in
  its own Task because runtime messages are untagged (same rationale as
  Valea.Agents.Doctor). stdin is closed: git must never prompt
  (GIT_TERMINAL_PROMPT=0; an ssh passphrase prompt dies at the timeout).
  """

  @callback run(String.t(), [String.t()], keyword()) ::
              {:ok, %{output: String.t(), exit: non_neg_integer()}}
              | {:error, :timeout | :git_not_found}

  @behaviour __MODULE__

  @default_timeout_ms 15_000
  @kill_grace_ms 2_000
  @output_cap 262_144

  @impl true
  def run(repo_root, args, opts \\ []) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        task = Task.async(fn -> spawn_and_await(git, repo_root, args, timeout_ms) end)

        case Task.yield(task, timeout_ms + @kill_grace_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _timeout_or_exit -> {:error, :timeout}
        end
    end
  end

  defp spawn_and_await(git, repo_root, args, timeout_ms) do
    spec = %{
      cmd: git,
      args: ["-C", repo_root | args],
      env: git_env(),
      cd: repo_root,
      stderr_path: nil,
      stdin: :closed
    }

    case Valea.Agents.ProcessRuntime.start(spec, self()) do
      {:ok, handle} -> collect(handle, [], System.monotonic_time(:millisecond) + timeout_ms)
      {:error, reason} -> {:error, :timeout} |> tap(fn _ -> require Logger; Logger.warning("git spawn failed: #{inspect(reason)}") end)
    end
  end

  defp collect(handle, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Valea.Agents.ProcessRuntime.stop(handle)
      {:error, :timeout}
    else
      receive do
        {:runtime_output, bin} -> collect(handle, [acc, bin], deadline)
        {:runtime_stderr, bin} -> collect(handle, [acc, bin], deadline)
        {:runtime_exit, code} -> {:ok, %{output: cap(IO.iodata_to_binary(acc)), exit: code || 1}}
      after
        remaining ->
          Valea.Agents.ProcessRuntime.stop(handle)
          {:error, :timeout}
      end
    end
  end

  defp cap(out) when byte_size(out) > @output_cap,
    do: binary_part(out, 0, @output_cap) <> "\n[output capped]"

  defp cap(out), do: out

  defp git_env do
    Valea.Agents.Env.minimal()
    |> put_env("GIT_TERMINAL_PROMPT", "0")
  end

  # Adapt to Env.minimal/0's actual shape (list of tuples vs map) — check how
  # backend/lib/valea/schedules/command_run.ex threads env into the runtime spec.
  defp put_env(env, k, v) when is_map(env), do: Map.put(env, k, v)
  defp put_env(env, k, v) when is_list(env), do: [{k, v} | List.keydelete(env, k, 0)]
end
```

Adjust `ProcessRuntime.start/2` handle usage to the real facade API (read `backend/lib/valea/agents/process_runtime.ex` and how `Valea.Agents.Doctor.probe/3` drives it) — the doctor's `probe` is the authoritative example of start/collect/stop against the facade.

- [ ] **Step 5: Implement `Valea.Git.Repo`**:

```elixir
defmodule Valea.Git.Repo do
  @moduledoc """
  Derives repo state and performs the four sanctioned mutations (commit_all,
  fetch, ff_merge, push) via a Cli module. Valea never merges (non-ff),
  rebases, or force-pushes — those verbs deliberately do not exist here.
  """

  @network_timeout_ms 60_000
  @conflict_codes ~w(DD AU UD UA DU AA UU)

  @type state :: %{
          branch: String.t() | nil,
          upstream: String.t() | nil,
          dirty: boolean(),
          conflicted: boolean(),
          in_progress: :merge | :rebase | :cherry_pick | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          local_sha: String.t() | nil,
          remote_sha: String.t() | nil
        }

  @spec detect(String.t()) :: :repo | {:unsupported, String.t()} | :none
  def detect(root) do
    dot_git = Path.join(root, ".git")

    cond do
      File.dir?(dot_git) ->
        :repo

      File.regular?(dot_git) ->
        {:unsupported, ".git is a file (linked worktree or submodule) — its gitdir lives outside this ICM"}

      enclosing_repo?(root) ->
        {:unsupported, "inside a git repository whose root is outside this ICM"}

      true ->
        :none
    end
  end

  defp enclosing_repo?(root) do
    root
    |> Path.dirname()
    |> ancestors()
    |> Enum.any?(&File.dir?(Path.join(&1, ".git")))
  end

  defp ancestors(path) do
    next = Path.dirname(path)
    if next == path, do: [path], else: [path | ancestors(next)]
  end

  @spec read_state(String.t(), module()) :: {:ok, state()} | {:error, term()}
  def read_state(root, cli) do
    with {:ok, porcelain} <- run0(root, ["status", "--porcelain"], cli) do
      lines = porcelain |> String.split("\n", trim: true)
      branch = read_branch(root, cli)
      upstream = read_upstream(root, cli)
      {ahead, behind} = read_counts(root, upstream, cli)

      {:ok,
       %{
         branch: branch,
         upstream: upstream,
         dirty: lines != [],
         conflicted: Enum.any?(lines, &(binary_part(&1, 0, 2) in @conflict_codes)),
         in_progress: in_progress(root),
         ahead: ahead,
         behind: behind,
         local_sha: rev_parse(root, "HEAD", cli),
         remote_sha: if(upstream, do: rev_parse(root, "@{u}", cli))
       }}
    end
  end

  defp read_branch(root, cli) do
    case cli.run(root, ["symbolic-ref", "--short", "-q", "HEAD"], []) do
      {:ok, %{exit: 0, output: out}} -> String.trim(out)
      _detached_or_error -> nil
    end
  end

  defp read_upstream(root, cli) do
    case cli.run(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], []) do
      {:ok, %{exit: 0, output: out}} -> String.trim(out)
      _no_upstream -> nil
    end
  end

  defp read_counts(_root, nil, _cli), do: {0, 0}

  defp read_counts(root, _upstream, cli) do
    case cli.run(root, ["rev-list", "--left-right", "--count", "HEAD...@{u}"], []) do
      {:ok, %{exit: 0, output: out}} ->
        case out |> String.trim() |> String.split(~r/\s+/) do
          [a, b] -> {String.to_integer(a), String.to_integer(b)}
          _other -> {0, 0}
        end

      _error ->
        {0, 0}
    end
  end

  defp rev_parse(root, ref, cli) do
    case cli.run(root, ["rev-parse", ref], []) do
      {:ok, %{exit: 0, output: out}} -> String.trim(out)
      _error -> nil
    end
  end

  defp in_progress(root) do
    git = Path.join(root, ".git")

    cond do
      File.exists?(Path.join(git, "MERGE_HEAD")) -> :merge
      File.dir?(Path.join(git, "rebase-merge")) -> :rebase
      File.dir?(Path.join(git, "rebase-apply")) -> :rebase
      File.exists?(Path.join(git, "CHERRY_PICK_HEAD")) -> :cherry_pick
      true -> nil
    end
  end

  @spec fetch(String.t(), module()) :: :ok | {:error, term()}
  def fetch(root, cli) do
    case cli.run(root, ["fetch", "--no-recurse-submodules", "--quiet"],
           timeout_ms: @network_timeout_ms
         ) do
      {:ok, %{exit: 0}} -> :ok
      {:ok, %{output: out}} -> {:error, {:fetch_failed, out}}
      {:error, reason} -> {:error, {:fetch_failed, inspect(reason)}}
    end
  end

  @spec commit_all(String.t(), String.t(), module()) :: :ok | {:error, {:commit_failed, String.t()}}
  def commit_all(root, message, cli) do
    with {:ok, %{exit: 0}} <- cli.run(root, ["add", "-A"], []),
         {:ok, %{exit: exit, output: out}} <- cli.run(root, ["commit", "-m", message], []) do
      if exit == 0 or out =~ "nothing to commit" or out =~ "nothing added to commit",
        do: :ok,
        else: {:error, {:commit_failed, out}}
    else
      {:ok, %{output: out}} -> {:error, {:commit_failed, out}}
      {:error, reason} -> {:error, {:commit_failed, inspect(reason)}}
    end
  end

  @spec ff_merge(String.t(), module()) :: :ok | {:error, {:ff_failed, String.t()}}
  def ff_merge(root, cli) do
    case cli.run(root, ["merge", "--ff-only", "@{u}"], []) do
      {:ok, %{exit: 0}} -> :ok
      {:ok, %{output: out}} -> {:error, {:ff_failed, out}}
      {:error, reason} -> {:error, {:ff_failed, inspect(reason)}}
    end
  end

  @spec push(String.t(), module()) :: :ok | {:error, term()}
  def push(root, cli) do
    case cli.run(root, ["push", "--quiet"], timeout_ms: @network_timeout_ms) do
      {:ok, %{exit: 0}} -> :ok
      {:ok, %{output: out}} ->
        if out =~ "[rejected]" or out =~ "non-fast-forward",
          do: {:error, {:push_rejected, out}},
          else: {:error, {:push_failed, out}}
      {:error, reason} -> {:error, {:push_failed, inspect(reason)}}
    end
  end

  @spec log_subjects(String.t(), String.t(), pos_integer(), module()) :: [String.t()]
  def log_subjects(root, range, cap, cli) do
    case cli.run(root, ["log", "--format=%s", "--max-count=#{cap}", range], []) do
      {:ok, %{exit: 0, output: out}} -> String.split(out, "\n", trim: true)
      _error -> []
    end
  end

  @spec changed_files(String.t(), pos_integer(), module()) :: [String.t()]
  def changed_files(root, cap, cli) do
    case cli.run(root, ["status", "--porcelain"], []) do
      {:ok, %{exit: 0, output: out}} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.sort_by(&(binary_part(&1, 0, 2) in @conflict_codes), :desc)
        |> Enum.map(&String.slice(&1, 3..-1//1))
        |> Enum.take(cap)

      _error ->
        []
    end
  end

  defp run0(root, args, cli) do
    case cli.run(root, args, []) do
      {:ok, %{exit: 0, output: out}} -> {:ok, out}
      {:ok, %{output: out}} -> {:error, {:git_error, out}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Note `detect/1` intentionally does NOT shell out (doctor/engine call it every pass); the enclosing-repo walk is a plain FS ancestor scan.

- [ ] **Step 6: Run tests to verify pass** — `cd backend && mix test test/valea/git/repo_test.exs`. Expected: PASS. Then full suite: `cd backend && mix test`.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/valea/git backend/test/support/git_fixtures.ex backend/test/valea/git
git commit -m "feat(git): Cli runner on ProcessRuntime + Repo state reader + git fixtures"
```

---

### Task 2: Mount git config + yaml block scalars + mounts doctor check

**Files:**
- Modify: `backend/lib/valea/mounts.ex` (new reader/writer near `skills_offers_dismissed` at `mounts.ex:637-675`; yaml renderer at `mounts.ex:1262-1326`)
- Modify: `backend/lib/valea/mounts/doctor.ex` (new check in `mount_checks/3` pipeline at `doctor.ex:194-226`)
- Test: `backend/test/valea/mounts_git_config_test.exs`, additions to `backend/test/valea/mounts/doctor_test.exs`

**Interfaces:**
- Consumes: Task 1's `Valea.Git.Repo.detect/1`, `Valea.Git.Repo.read_state/2`, `Valea.Git.Cli`.
- Produces:
  - `Valea.Mounts.git_config(workspace :: String.t(), mount_key :: String.t()) :: %{sync: :full | :pull | :off, instructions: String.t() | nil}` — absent/malformed block ⇒ `%{sync: :pull, instructions: nil}` (spec: detected repos default to pull; degrade-tolerant house style).
  - `Valea.Mounts.set_git_sync(workspace, mount_key, mode :: String.t()) :: :ok | {:error, term()}` — `mode in ~w(full pull off)`, preserves sibling `instructions`, `{:error, :invalid_git_sync}` otherwise.
  - workspace.yaml round-trips multiline string values as YAML block scalars (`key: |`).
  - Doctor check id `"git_sync:<mount_key>"`, label `"Git sync"`.

- [ ] **Step 1: Write failing config tests** — `backend/test/valea/mounts_git_config_test.exs`. Follow the setup style of the existing mounts tests (see how `test/valea/mounts_test.exs` or the watcher test builds a workspace + external ICM: `test/valea/icm/watcher_test.exs:574-620` `external_icm!/declare_external!`). Cases, each a real test with full asserts:

```elixir
defmodule Valea.MountsGitConfigTest do
  use ExUnit.Case, async: false

  # setup: open_workspace!() from AgentCase + mount_test_icm!(ws, name: "Repo")
  # (see backend/test/support/agent_case.ex:132, :205)

  test "git_config defaults to pull when block is absent", %{ws: ws, mount: m} do
    assert %{sync: :pull, instructions: nil} = Valea.Mounts.git_config(ws, m.mount_key)
  end

  test "git_config parses sync + instructions; malformed sync degrades to pull", %{ws: ws, mount: m} do
    put_git_block!(ws, m.mount_key, ~s(    git:\n      sync: "yolo"\n      instructions: |\n        Merge, never rebase.\n))
    assert %{sync: :pull, instructions: "Merge, never rebase."} =
             Valea.Mounts.git_config(ws, m.mount_key)
  end

  test "set_git_sync validates mode and mount", %{ws: ws, mount: m} do
    assert {:error, :invalid_git_sync} = Valea.Mounts.set_git_sync(ws, m.mount_key, "yolo")
    assert {:error, _} = Valea.Mounts.set_git_sync(ws, "no-such-mount", "pull")
  end

  test "set_git_sync preserves instructions and other entry keys", %{ws: ws, mount: m} do
    put_git_block!(ws, m.mount_key, ~s(    git:\n      instructions: "keep both"\n))
    :ok = Valea.Mounts.set_git_sync(ws, m.mount_key, "off")
    assert %{sync: :off, instructions: "keep both"} = Valea.Mounts.git_config(ws, m.mount_key)
    {:ok, [mount]} = {:ok, Valea.Mounts.list(ws) |> Enum.filter(&(&1.name == m.mount_key))}
    assert mount.enabled and mount.degraded == nil
  end

  test "multiline instructions survive a config rewrite (block scalar)", %{ws: ws, mount: m} do
    put_git_block!(ws, m.mount_key, ~s(    git:\n      instructions: |\n        Never rebase.\n        Merge and keep both versions.\n))
    :ok = Valea.Mounts.set_git_sync(ws, m.mount_key, "full")
    raw = File.read!(Path.join(ws, "config/workspace.yaml"))
    assert raw =~ "instructions: |"
    assert raw =~ "Never rebase."
    assert raw =~ "Merge and keep both versions."
    assert %{sync: :full, instructions: "Never rebase.\nMerge and keep both versions."} =
             Valea.Mounts.git_config(ws, m.mount_key)
  end

  # Appends yaml lines under the mount's icms entry by rewriting the file:
  # read config/workspace.yaml, find the "  <mount_key>:" line, insert the
  # block after the entry's existing keys (they are two-space-deeper lines),
  # write back. The watcher test's declare_external! (watcher_test.exs:574)
  # shows the exact file shape this manipulates.
  defp put_git_block!(ws, mount_key, yaml_block) do
    path = Path.join(ws, "config/workspace.yaml")
    lines = path |> File.read!() |> String.split("\n")
    idx = Enum.find_index(lines, &(&1 == "  #{mount_key}:"))
    rest = Enum.drop(lines, idx + 1)
    entry_len = Enum.count(Enum.take_while(rest, &String.starts_with?(&1, "    ")))
    {head, tail} = Enum.split(lines, idx + 1 + entry_len)
    File.write!(path, Enum.join(head ++ [String.trim_trailing(yaml_block, "\n")] ++ tail, "\n"))
  end
end
```

- [ ] **Step 2: Run to verify failure** — `mix test test/valea/mounts_git_config_test.exs` → undefined function errors.

- [ ] **Step 3: Implement in `mounts.ex`.** Reader + writer beside `skills_offers_dismissed` (same gates: `validate_mount_name/1`, `ensure_icm_present/2`, `write_icms/2`):

```elixir
@git_sync_modes ~w(full pull off)

@doc """
Per-mount git sync policy. Absent or malformed block degrades to the safe
default (%{sync: :pull, instructions: nil}) — never raises, mirroring
skills_offers_dismissed/2.
"""
@spec git_config(String.t(), String.t()) ::
        %{sync: :full | :pull | :off, instructions: String.t() | nil}
def git_config(workspace, mount_key) do
  case workspace |> read_icms_config() |> Map.get(mount_key) do
    %{"git" => %{} = git} ->
      %{sync: parse_git_sync(Map.get(git, "sync")), instructions: parse_git_instructions(Map.get(git, "instructions"))}

    _absent_or_malformed ->
      %{sync: :pull, instructions: nil}
  end
end

defp parse_git_sync("full"), do: :full
defp parse_git_sync("off"), do: :off
defp parse_git_sync(_pull_or_invalid), do: :pull

defp parse_git_instructions(text) when is_binary(text) and text != "", do: text
defp parse_git_instructions(_absent_or_invalid), do: nil

@spec set_git_sync(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
def set_git_sync(workspace, mount_key, mode) when mode in @git_sync_modes do
  with :ok <- validate_mount_name(mount_key),
       {:ok, doc} <- read_workspace_config_for_write(workspace),
       icms = Map.get(doc, "icms", %{}),
       :ok <- ensure_icm_present(icms, mount_key) do
    icms =
      Map.update!(icms, mount_key, fn entry ->
        Map.update(entry, "git", %{"sync" => mode}, &Map.put(&1, "sync", mode))
      end)

    write_icms(workspace, Map.put(doc, "icms", icms))
  end
end

def set_git_sync(_workspace, _mount_key, _mode), do: {:error, :invalid_git_sync}
```

Match the exact helper names/arities in the current `skills_offers_dismissed` writer (`mounts.ex:662-675`) — if `write_icms/2` takes `(workspace, icms)` rather than the whole doc, follow that.

- [ ] **Step 4: Block-scalar renderer.** In the recursive renderer (`render_yaml_entry/3`, `mounts.ex:1282-1306`), add a binary-with-newline branch BEFORE the scalar fallback:

```elixir
defp render_yaml_entry(key, value, indent) when is_binary(value) do
  if String.contains?(value, "\n") do
    lines = value |> String.trim_trailing("\n") |> String.split("\n")
    ["#{indent}#{yaml_key(key)}: |" | Enum.map(lines, &(indent <> "  " <> &1))]
  else
    ["#{indent}#{yaml_key(key)}: #{render_scalar(value)}"]
  end
end
```

(Existing single-line strings keep flowing through `render_scalar/1` — `Valea.Yaml.escape/1` flattens control chars, which is exactly why multiline needs this branch.)

- [ ] **Step 5: Doctor check.** In `mounts/doctor.ex`, append a `git_sync` check to the per-mount pipeline (`mount_checks/3` list at `doctor.ex:203` AND the gated-`unknown` fallback list at `doctor.ex:206-224`):

```elixir
@git_label "Git sync"

defp git_sync_check(mount, workspace) do
  id = check_id(mount, "git_sync")
  cfg = Valea.Mounts.git_config(workspace, mount.name)

  case Valea.Git.Repo.detect(mount.root) do
    :none ->
      ok(id, @git_label, "not a git repository — git sync not applicable.")

    {:unsupported, reason} ->
      failed(id, @git_label, reason, "Mount the repository root directly, or leave git sync off.")

    :repo ->
      git_repo_check(id, mount, cfg)
  end
end

defp git_repo_check(id, mount, cfg) do
  cond do
    System.find_executable("git") == nil ->
      failed(id, @git_label, "git binary not found on PATH.", "Install git or launch Valea from an environment where git is on PATH.")

    cfg.sync == :off ->
      ok(id, @git_label, "git repository detected — sync is off.")

    true ->
      case Valea.Git.Repo.read_state(mount.root, git_cli()) do
        {:ok, %{branch: nil}} ->
          failed(id, @git_label, "detached HEAD — sync follows the checked-out branch.", "Check out a branch in this repository.")

        {:ok, %{upstream: nil, branch: branch}} ->
          failed(id, @git_label, "branch #{branch} has no upstream — observe-only.", "git branch --set-upstream-to=origin/#{branch} #{branch}")

        {:ok, %{branch: branch, upstream: upstream}} ->
          ok(id, @git_label, "#{branch} ↔ #{upstream} · mode #{cfg.sync}.")

        {:error, _reason} ->
          unknown(id, @git_label, "could not read repository state.")
      end
  end
end

defp git_cli, do: Application.get_env(:valea, :git_cli, Valea.Git.Cli)
```

- [ ] **Step 6: Doctor tests.** Add to `backend/test/valea/mounts/doctor_test.exs`, using `GitFixtures` (skip-if-no-git tag on these tests): non-repo mount → ok "not applicable"; repo with upstream → ok with branch/mode; `.git`-file mount → failed with worktree wording; no-upstream repo (init without remote) → failed with the `--set-upstream-to` remedy.

- [ ] **Step 7: Run** — `mix test test/valea/mounts_git_config_test.exs test/valea/mounts/doctor_test.exs`, then the full backend suite. Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/lib/valea/mounts.ex backend/lib/valea/mounts/doctor.ex backend/test
git commit -m "feat(git): per-mount git sync config, yaml block scalars, mounts-doctor check"
```

---

### Task 3: `Valea.Git.Engine`

**Files:**
- Create: `backend/lib/valea/git/engine.ex`
- Create: `backend/lib/valea/git/briefing.ex`
- Modify: `backend/lib/valea/workspace/runtime.ex:14-24` (add child)
- Test: `backend/test/valea/git/engine_test.exs`, `backend/test/valea/git/briefing_test.exs`

**Interfaces:**
- Consumes: Task 1 `Valea.Git.Cli`/`Valea.Git.Repo` (all functions listed there); Task 2 `Valea.Mounts.git_config/2`; `Valea.Mounts.list/1` mount maps `%{name, root, manifest, enabled, degraded, kind}` (`mounts.ex:119-126`, filter `kind == :icm`, `enabled: true`, `degraded: nil`); PubSub topics `"workspace"` (`{:workspace_opened, info, generation}` / `{:workspace_closed}`), `"icm"` (`{:icm_changed}`), `"mounts"` (`{:mounts_changed}`).
- Produces (Tasks 4–5 rely on these):
  - Child of `Valea.Workspace.Runtime`, `name: __MODULE__`, cfg `%{root: String.t(), generation: integer()}` (+ optional `activate: true` for tests, mail pattern).
  - `Valea.Git.Engine.statuses() :: %{String.t() => status()}` — `%{}` when engine absent/inactive. `status() :: %{mount_key: String.t(), icm_name: String.t(), mode: String.t(), state: String.t(), reason: String.t() | nil, branch: String.t() | nil, ahead: non_neg_integer(), behind: non_neg_integer(), dirty: boolean(), last_sync_at: String.t() | nil, last_error: String.t() | nil, conflict_session_id: String.t() | nil}` with `state ∈ "ok" | "syncing" | "diverged" | "blocked_local" | "merge_in_progress" | "error" | "off" | "detached" | "no_upstream" | "unsupported"`.
  - `Valea.Git.Engine.sync_now(mount_key) :: :ok | {:error, :not_found | :not_running}` — bypasses backoff.
  - `Valea.Git.Engine.conflict_handoff(mount_key) :: {:ok, %{briefing: String.t(), existing_session_id: String.t() | nil, icm_name: String.t()}} | {:error, :no_conflict | :not_found | :not_running}` — re-derives live state before answering.
  - `Valea.Git.Engine.record_conflict_session(mount_key, session_id) :: :ok` (cast).
  - PubSub: `Phoenix.PubSub.broadcast(Valea.PubSub, "git", {:git_status_changed, statuses_map})` after every pass and on conflict-session recording.
  - `Valea.Git.Briefing.compose(details :: map(), instructions :: String.t() | nil) :: String.t()`.
  - App-env seams: `:git_cli` (default `Valea.Git.Cli`, pinned at init), `:git_poll_interval_ms` (default 300_000), `:git_poll_jitter` (int ms | `:random`, max 60_000), `:git_commit_quiet_ms` (default 120_000), `:git_sync_probe` (test pid receiving `{:git_pass_finished, statuses}` after each pass — mirror mail's `:engine_sync_probe` usage).

**Engine behavior spec (implement exactly):**

- `init`: trap_exit, subscribe `"workspace"`, `"icm"`, `"mounts"`; pin `cli`; state `%{root, generation, cli, active: false, repos: %{}, retry: %{}, poll_timer: nil, commit_timer: nil, sync_task: nil, pending_sync: false}`. `activate: true` cfg ⇒ `{:continue, :activate_now}`.
- Activation gating exactly like mail (`engine.ex:1134`): `{:workspace_opened, _info, generation}` matching own generation ⇒ activate (initial pass + schedule poll); other generations ignored; `{:workspace_closed}` ⇒ deactivate (cancel timers, forget statuses).
- `:poll` ⇒ start pass unless busy, reschedule. `{:icm_changed}` ⇒ (when any full-mode repo exists) re-arm `commit_timer` for `@commit_quiet_ms`; flush ⇒ start pass. `{:mounts_changed}` ⇒ start pass (config/eligibility may have changed).
- The pass runs in ONE linked+monitored task (mail's `spawn_linked_task` pattern, `mail/engine.ex:2300-2350`): iterate repos sequentially, return `%{mount_key => status}`; engine merges, updates `retry`, broadcasts, sends probe. Second trigger while busy sets `pending_sync` (re-pass on task exit). Task EXIT/crash: log, clear `sync_task`, keep last statuses.
- Per-repo pass algorithm (inside the task; `cfg = Mounts.git_config/2`, `detect = Repo.detect/1`):
  1. `detect` `:none` and no explicit `git:` block ⇒ no status row. `:none` with a block ⇒ `unsupported`/"no git repository". `{:unsupported, reason}` ⇒ `unsupported` + reason.
  2. mode `off` ⇒ status `off`, nothing else.
  3. `read_state`: `branch nil` ⇒ `detached`; `upstream nil` ⇒ `no_upstream` (observe-only rows still carry branch/dirty).
  4. `in_progress != nil or conflicted` ⇒ `merge_in_progress`. Held: stop.
  5. `ahead > 0 and behind > 0` ⇒ `diverged`. Held: stop (no fetch — held means held).
  6. mode `full` and dirty ⇒ `commit_all(root, "valea sync: " <> DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second)), cli)`; failure ⇒ `error`.
  7. Backoff gate: if `retry[mount_key].retry_at` is in the future and this isn't a `sync_now`-forced pass for the repo ⇒ keep previous `error` status, skip network. Else `fetch`; failure ⇒ `error` (+ backoff bump: `retry_at = now + min(60_000 * 2^(n-1), 1_800_000)`).
  8. Re-`read_state`. behind>0 & ahead==0 ⇒ `ff_merge`; `{:error, {:ff_failed, out}}` ⇒ re-`read_state`: now diverged ⇒ `diverged`, else `blocked_local` (out into `last_error`). ahead>0 & behind==0 & mode full ⇒ `push`; `{:push_rejected, _}` ⇒ `fetch` + re-read ⇒ almost certainly `diverged`. both>0 after fetch ⇒ `diverged`.
  9. Success ⇒ `ok`, `last_sync_at` now, clear retry entry.
  - Conflict-class states (`diverged | blocked_local | merge_in_progress`) keep any previously recorded `conflict_session_id`; entering `ok` clears it. During the pass, a recorded session id that is no longer running (checked by the server process after task merge via `Valea.Agents.SessionServer.attach/1` match — see Task 4 note) is cleared.
- `{:conflict_handoff, mount_key}` (call, in server, NOT the task — quick local reads only): repo row must exist and be conflict-class; re-run `read_state`; if no longer conflict-class ⇒ refresh row + `{:error, :no_conflict}`. Else gather `local_subjects = Repo.log_subjects(root, "@{u}..HEAD", 10, cli)`, `remote_subjects = Repo.log_subjects(root, "HEAD..@{u}", 10, cli)`, `files = Repo.changed_files(root, 20, cli)`, `instructions = Mounts.git_config(root_ws, mount_key).instructions`, reply `{:ok, %{briefing: Briefing.compose(details, instructions), existing_session_id: row.conflict_session_id, icm_name: row.icm_name}}`.

- [ ] **Step 1: Write `Valea.Git.Briefing` + its test first** (pure function, no process):

```elixir
defmodule Valea.Git.Briefing do
  @moduledoc "Composes the deterministic conflict briefing sent as the session's first user message."

  @spec compose(map(), String.t() | nil) :: String.t()
  def compose(d, instructions) do
    """
    Git sync needs help in the "#{d.icm_name}" ICM (branch #{d.branch || "detached"}, sync mode #{d.mode}).

    Situation: #{situation(d)}

    Local-only commits (#{d.ahead}):
    #{bullet_list(d.local_subjects)}
    Remote-only commits (#{d.behind}):
    #{bullet_list(d.remote_subjects)}
    Files needing attention:
    #{bullet_list(d.files)}
    Resolve this so local and remote converge without losing either side's intent.
    - Inspect first: git status, git log --oneline --left-right @{u}...HEAD
    - Merge or rebase at your judgment. Never force-push. Never discard changes silently.
    - When the tree is clean and the branch is level with its upstream, push.
    - Finish with a short summary of what you did.
    #{per_icm(instructions)}\
    """
  end

  defp situation(%{state: "diverged"} = d),
    do: "local and remote have both moved (#{d.ahead} ahead / #{d.behind} behind) — Valea holds and never merges."

  defp situation(%{state: "blocked_local"}),
    do: "the remote moved but uncommitted local edits block the fast-forward."

  defp situation(%{state: "merge_in_progress"}),
    do: "a merge/rebase was left unfinished in the working tree (conflict markers may be present)."

  defp situation(_other), do: "the repository needs reconciliation."

  defp bullet_list([]), do: "- (none)\n"
  defp bullet_list(items), do: Enum.map_join(items, "", &"- #{&1}\n")

  defp per_icm(nil), do: ""
  defp per_icm(text), do: "\nICM-specific instructions:\n#{text}\n"
end
```

Test (`briefing_test.exs`): diverged briefing contains icm name, both counts, each subject, each file, the never-force-push line, and appended instructions; nil instructions ⇒ no "ICM-specific" header; empty lists render "(none)".

- [ ] **Step 2: Write failing engine tests** — `backend/test/valea/git/engine_test.exs`. `async: false`; skip module without git. Setup builds tmp dir + `GitFixtures.remote_and_clones!`, a fake workspace root with `config/workspace.yaml` declaring the `work` clone as an external ICM (copy the yaml-writing helper from `test/valea/icm/watcher_test.exs:574` `declare_external!` — it needs an `icm.yaml` in the mount too, use `Valea.Mounts.Manifest.write!` as `external_icm!/1` does at `watcher_test.exs:603`). Engine helpers:

```elixir
defp start_engine!(root, generation) do
  Application.put_env(:valea, :git_sync_probe, self())
  Application.put_env(:valea, :git_poll_interval_ms, 3_600_000)
  on_exit(fn ->
    Application.delete_env(:valea, :git_sync_probe)
    Application.delete_env(:valea, :git_poll_interval_ms)
  end)
  start_supervised!({Valea.Git.Engine, %{root: root, generation: generation, activate: true}})
end

defp await_pass! do
  assert_receive {:git_pass_finished, statuses}, 5_000
  statuses
end
```

Tests (full code in the file; the assertions shown here are the required behavior):

1. **inert until matching generation**: start WITHOUT `activate`, broadcast `{:workspace_opened, %{}, other_gen}` ⇒ `statuses() == %{}`; broadcast matching gen ⇒ pass runs, row present with `state: "ok"`, `mode: "pull"`.
2. **pull behind ⇒ ff**: `advance_remote!`, `sync_now(key)` ⇒ pass; work's HEAD == other's pushed sha; `state: "ok"`, `behind: 0`.
3. **pull mode never pushes**: `advance_local!` ⇒ after pass `state: "ok"`, `ahead: 1`, and the bare remote's `main` sha unchanged.
4. **full dirty ⇒ commit+push**: `set_git_sync(ws, key, "full")`; write an uncommitted file; pass ⇒ remote sha advanced, commit subject starts `"valea sync: "`, `state: "ok"`.
5. **diverged ⇒ held**: `diverge!` ⇒ `state: "diverged"`; capture both shas; run `sync_now` again ⇒ shas unchanged (no fetch/ff/push happened — assert bare and work HEADs identical to before).
6. **blocked_local**: remote edits `seed.md`, local uncommitted edit to `seed.md` (pull mode) ⇒ `state: "blocked_local"`, `last_error` non-nil, file content preserved.
7. **merge_in_progress**: `conflict!` ⇒ `state: "merge_in_progress"`; pass performs no mutations.
8. **off / no_upstream / unsupported rows**: `set_git_sync ⇒ "off"` ⇒ `state: "off"`; a second mount whose repo has no upstream ⇒ `no_upstream`; a `.git`-file mount ⇒ `unsupported` with reason.
9. **fetch failure ⇒ error + backoff**: `File.rm_rf!(bare)` ⇒ pass ⇒ `state: "error"`; immediately trigger a poll-driven pass (send `:poll`) ⇒ probe fires but no new fetch attempt occurred (assert `last_error` timestamp/value unchanged — expose attempt counting via the retry map in the status's `last_error` or assert elapsed via a 3rd `sync_now` which DOES retry and re-errors).
10. **icm_changed debounce commits in full mode**: `git_commit_quiet_ms: 50`; write file; `Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})` ⇒ within 5s a pass commits it.
11. **conflict_handoff**: on diverged repo ⇒ `{:ok, %{briefing: b, existing_session_id: nil}}`, `b =~ "local: local.md"`; `record_conflict_session(key, "sess-1")` ⇒ statuses carry it; resolve manually in fixture (merge in `work` via System.cmd + push), `sync_now` ⇒ `state: "ok"`, `conflict_session_id: nil`; now `conflict_handoff` ⇒ `{:error, :no_conflict}`.
12. **broadcast**: subscribe test pid to `"git"` ⇒ after pass receive `{:git_status_changed, %{^key => _}}`.

- [ ] **Step 3: Run to verify failure** — `mix test test/valea/git/engine_test.exs` → module undefined.

- [ ] **Step 4: Implement `Valea.Git.Engine`** per the behavior spec above. Skeleton pins (copy idioms from `backend/lib/valea/mail/engine.ex` at the cited lines — activation `:1134`, spawn_linked_task `:2300-2350`, schedule/jitter `:2586-2626`):

```elixir
defmodule Valea.Git.Engine do
  use GenServer
  require Logger

  @default_interval_ms 300_000
  @max_jitter_ms 60_000
  @commit_quiet_default_ms 120_000
  @backoff_base_ms 60_000
  @backoff_cap_ms 1_800_000
  @conflict_states ~w(diverged blocked_local merge_in_progress)

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  def statuses do
    case Process.whereis(__MODULE__) do
      nil -> %{}
      pid -> GenServer.call(pid, :statuses)
    end
  catch
    :exit, _ -> %{}
  end

  def sync_now(mount_key) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:sync_now, mount_key})
    end
  end

  def conflict_handoff(mount_key) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:conflict_handoff, mount_key}, 30_000)
    end
  end

  def record_conflict_session(mount_key, session_id),
    do: GenServer.cast(__MODULE__, {:record_conflict_session, mount_key, session_id})

  # … init/handle_* per the behavior spec …
end
```

Status rows are built inside the pass task; the task returns `{new_statuses, new_retry}`; server merges, broadcasts `{:git_status_changed, statuses}` on `"git"`, probes `:git_sync_probe`. `sync_now` validates the mount_key against current eligible mounts (`{:error, :not_found}` otherwise), clears that repo's retry entry, then starts/queues a pass with that repo marked forced.

- [ ] **Step 5: Wire supervision** — add to `backend/lib/valea/workspace/runtime.ex` children (after `Valea.Schedules.Supervisor`):

```elixir
{Valea.Git.Engine, %{root: root, generation: gen}},
```

- [ ] **Step 6: Run engine + briefing tests, then full backend suite.** Expected: PASS. Watch for: engine tests must not leak the probe env (on_exit), and runtime.ex change must not break existing workspace manager tests.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/valea/git backend/lib/valea/workspace/runtime.ex backend/test/valea/git
git commit -m "feat(git): per-workspace sync engine — passes, holds, backoff, conflict handoff"
```

---

### Task 4: RPCs, channel push, cockpit block

**Files:**
- Create: `backend/lib/valea/api/git.ex`
- Modify: `backend/lib/valea/api.ex` (register resource + rpc_actions, pattern at `api.ex:105-124`)
- Modify: `backend/lib/valea_web/channels/workspace_events_channel.ex` (join subscribe `"git"` at `:5-11`; new handle_info)
- Modify: `backend/lib/valea/cockpit.ex` (git block in `today/0` at `:79-88`) and `backend/lib/valea/api/cockpit.ex` (constraints)
- Test: `backend/test/valea_web/git_rpc_test.exs`, additions to the channel test + cockpit test files (find them via `grep -rl "workspace:events" backend/test` and `grep -rl "cockpit_today" backend/test`)

**Interfaces:**
- Consumes: Task 3 engine API (`statuses/0`, `sync_now/1`, `conflict_handoff/1`, `record_conflict_session/2`), Task 2 `Mounts.set_git_sync/3`. Session machinery exactly as `revise_mail_draft` uses it: `Valea.Agents.generate_session_id/0`, `Valea.Agents.SessionScope.resolve/1` (`session_scope.ex:83`), `Valea.Agents.start_session/1` (`agents.ex:39-55`, accepts `title:`), `Valea.Agents.SessionServer.attach/1` for liveness, `Valea.Audit.append/2` (mirror the call at `api/agents.ex:153-159`). `Manager.check_generation/1`, `Manager.current/0`. Error mapping: write a local `error_for/1` modeled on `Valea.Api.Icms.error_for/1` (`icms.ex:407-411`).
- Produces:
  - RPC `git_status(generation)` → `%{"repos" => [status-map]}` (untyped `{:array, :map}`, snake string keys).
  - RPC `git_sync_now(mount_key, generation)` → `%{"started" => true}`.
  - RPC `set_icm_git_sync(mount_key, sync, generation)` → `%{"saved" => true}` + `Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})` (engine re-passes; copy the `broadcast_mounts_changed` helper usage from `api/icms.ex`).
  - RPC `start_git_conflict_session(mount_key, generation)` → `%{"session_id" => id, "routed" => "existing" | "new"}`; errors: `:no_conflict` → `"No git conflict to resolve — it may have just cleared."`.
  - Channel push event `"git_status"` payload `%{"repos" => [stringified status]}`.
  - Cockpit `today/0` gains top-level `"git" => [status-map]` (string keys, sorted by mount_key, rescue/catch ⇒ `[]`).
  - rpc_action names: `:git_status`, `:git_sync_now`, `:set_icm_git_sync`, `:start_git_conflict_session`.

- [ ] **Step 1: Write failing RPC tests** — `backend/test/valea_web/git_rpc_test.exs`. Mirror the harness of `backend/test/valea_web/agents_rpc_test.exs` (workspace via `AgentCase.open_workspace!`, fake harness cmd via `AgentCase.fake_cmd` — see `agents_rpc_test.exs:273` for the initial_prompt-carrying create test). Git-needing tests tagged/skipped without git. Cases:

```elixir
test "git_status returns engine rows" do
  # fixture mount + engine (activate: true) + sync_now; then RPC git_status
  # assert %{"repos" => [%{"mount_key" => _, "state" => "ok"} | _]} shape
end

test "git_sync_now starts a pass and set_icm_git_sync persists" do
  # RPC git_sync_now → %{"started" => true}
  # RPC set_icm_git_sync(key, "full") → %{"saved" => true}; Mounts.git_config now :full
  # stale generation → error "workspace_changed" wording via error_for
end

test "start_git_conflict_session composes briefing and starts a chat session" do
  # diverge! fixture; RPC → %{"session_id" => id, "routed" => "new"}
  # session meta (Valea.Agents.session_meta(id) — agents.ex:492) has kind "chat",
  #   icm_mount == mount_key, title == "Git sync conflict — " <> icm_name
  # transcript line for the user echo contains "Local-only commits" (initial_prompt enqueued)
  # second RPC while session lives → routed "existing", same id
end

test "start_git_conflict_session on a clean repo errors no_conflict" do
  # RPC → {:error, …} mapped message contains "No git conflict"
end
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `Valea.Api.Git`:**

```elixir
defmodule Valea.Api.Git do
  @moduledoc """
  Git sync RPCs. Top-level booleans use string keys (ash_typescript falsy
  rule — canonical note in Valea.Api.Mail). Repo rows ride untyped
  {:array, :map} so their snake_case string keys and booleans pass through
  unmangled (array items are exempt from the falsy bug).
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  alias Valea.Git.Engine
  alias Valea.Workspace.Manager

  # … typescript/attributes boilerplate copied from Valea.Api.Skills …

  actions do
    action :git_status, :map do
      constraints fields: [repos: [type: {:array, :map}, allow_nil?: false]]
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation) do
          repos =
            Engine.statuses()
            |> Map.values()
            |> Enum.map(&stringify/1)
            |> Enum.sort_by(& &1["mount_key"])

          {:ok, %{"repos" => repos}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :git_sync_now, :map do
      constraints fields: [started: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- Engine.sync_now(key) do
          {:ok, %{"started" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_icm_git_sync, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :sync, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: key, sync: sync, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- Valea.Mounts.set_git_sync(root, key, sync) do
          Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :start_git_conflict_session, :map do
      constraints fields: [
                    session_id: [type: :string, allow_nil?: false],
                    routed: [type: :string, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             {:ok, handoff} <- Engine.conflict_handoff(key) do
          route(key, generation, handoff)
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  defp route(key, generation, %{existing_session_id: id} = handoff) when is_binary(id) do
    if session_running?(id) do
      {:ok, %{"session_id" => id, "routed" => "existing"}}
    else
      start_conflict_session(key, generation, handoff)
    end
  end

  defp route(key, generation, handoff), do: start_conflict_session(key, generation, handoff)

  defp start_conflict_session(key, generation, %{briefing: briefing, icm_name: icm_name}) do
    id = Valea.Agents.generate_session_id()

    with {:ok, scope} <-
           Valea.Agents.SessionScope.resolve(%{
             kind: "chat",
             mount_key: key,
             generation: generation,
             session_id: id,
             read_paths: []
           }),
         {:ok, %{id: ^id}} <-
           Valea.Agents.start_session(%{
             id: id,
             kind: "chat",
             title: "Git sync conflict — #{icm_name}",
             scope: scope,
             run: nil,
             initial_prompt: briefing,
             on_turn_end: nil,
             context_doc: nil,
             input: nil
           }) do
      Engine.record_conflict_session(key, id)
      # Audit: mirror the session_started append in Valea.Api.Agents (api/agents.ex:153-159)
      {:ok, %{"session_id" => id, "routed" => "new"}}
    else
      {:error, reason} -> {:error, error_for(reason)}
    end
  end

  defp session_running?(id),
    do: match?({:ok, _}, Valea.Agents.SessionServer.attach(id))

  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)

  defp error_for(:no_conflict), do: "No git conflict to resolve — it may have just cleared."
  defp error_for(:not_found), do: "This ICM is not a syncing git repository."
  defp error_for(:not_running), do: "Git engine is not running — is a workspace open?"
  defp error_for(:invalid_git_sync), do: "sync must be one of: full, pull, off."
  # fall through to the shared wording for workspace_changed etc. — copy the
  # remaining clauses from Valea.Api.Icms.error_for/1
end
```

Match the resource boilerplate (typescript name block etc.) to `backend/lib/valea/api/skills.ex` — it is the smallest existing Api resource. Register in `backend/lib/valea/api.ex`:

```elixir
resource Valea.Api.Git do
  rpc_action :git_status, :git_status
  rpc_action :git_sync_now, :git_sync_now
  rpc_action :set_icm_git_sync, :set_icm_git_sync
  rpc_action :start_git_conflict_session, :start_git_conflict_session
end
```

- [ ] **Step 4: Channel + cockpit.** `workspace_events_channel.ex`: add `Phoenix.PubSub.subscribe(Valea.PubSub, "git")` in join and

```elixir
def handle_info({:git_status_changed, statuses}, socket) do
  repos = statuses |> Map.values() |> Enum.map(&stringify/1) |> Enum.sort_by(& &1["mount_key"])
  push(socket, "git_status", %{"repos" => repos})
  {:noreply, socket}
end
```

`cockpit.ex`: add `"git" => git_summary()` to `today/0` and

```elixir
defp git_summary do
  Valea.Git.Engine.statuses()
  |> Map.values()
  |> Enum.map(fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end)
  |> Enum.sort_by(& &1["mount_key"])
rescue
  _any -> []
catch
  :exit, _reason -> []
end
```

`api/cockpit.ex`: add `git: [type: {:array, :map}, allow_nil?: false]` to the `:today` constraints (`api/cockpit.ex:54+`).

- [ ] **Step 4b: Doctor picks up live engine outcome.** The spec's doctor section includes "last fetch/push outcome". Now that the engine exists, extend `git_repo_check/3` in `mounts/doctor.ex` (from Task 2): when `Valea.Git.Engine.statuses()[mount.name]` exists and its `state == "error"`, report `failed(id, @git_label, "last sync failed: " <> (status.last_error || "unknown"), auth_remedy(status.last_error))` instead of the plain ok — where `auth_remedy/1` returns the ssh-agent hint (`"If this is an auth failure: the packaged app may lack your ssh-agent environment — try launching from a terminal, or check the remote's credentials."`) when the error text matches `~r/auth|permission|denied|publickey/i`, else `nil`-remedy via `unknown/3`… keep it one small cond. Wrap the `Engine.statuses()` read in the same rescue/catch-`:exit`-to-`%{}` posture the cockpit uses. Add one doctor test: fabricate an engine row with `state: "error", last_error: "Permission denied (publickey)"` (start an engine against a fixture whose bare remote was deleted, or set the row via a pass) and assert the failed check carries the hint.

- [ ] **Step 5: Channel + cockpit tests.** Channel: broadcast a fabricated `{:git_status_changed, %{"k" => %{mount_key: "k", state: "diverged", ahead: 1, behind: 2, dirty: false, mode: "pull", icm_name: "K", reason: nil, branch: "main", last_sync_at: nil, last_error: nil, conflict_session_id: nil}}}` on `"git"`; `assert_push "git_status", %{"repos" => [row]}`; assert the whole row payload (whole-payload pin, the mail_oauth precedent). Cockpit: with no engine ⇒ `"git" => []`; with a fixture engine ⇒ row present.

- [ ] **Step 6: Codegen** — `just codegen`; commit the regenerated `frontend/src/lib/api/ash_rpc.ts`. Run backend suite.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/valea/api.ex backend/lib/valea/api/git.ex backend/lib/valea_web backend/lib/valea/cockpit.ex backend/lib/valea/api/cockpit.ex backend/test frontend/src/lib/api/ash_rpc.ts
git commit -m "feat(git): status/sync/config/conflict-session RPCs, channel push, cockpit block"
```

---

### Task 5: Frontend — store, Today section, sidebar badge, per-ICM modal

**Files:**
- Create: `frontend/src/lib/stores/git.svelte.ts` (+ colocated `git.svelte.test.ts`, following the existing vitest layout under `frontend/src`)
- Create: `frontend/src/lib/components/shell/GitSyncModal.svelte`
- Modify: `frontend/src/lib/api/client.ts` (wrappers + fields consts + cockpit `git` field)
- Modify: `frontend/src/lib/socket.ts` (typed `git_status` push), `frontend/src/lib/stores/icm.svelte.ts:657` (`wireGitEvents(channel)` beside `wireMailEvents`)
- Modify: `frontend/src/lib/today/cockpit.ts` (type + normalizer + notice text helper), `frontend/src/routes/+page.svelte` (git attention section + refresh subscription)
- Modify: `frontend/src/lib/components/shell/IcmProjects.svelte` (badge + dropdown item)

**Interfaces:**
- Consumes: RPCs `gitStatus(generation)`, `gitSyncNow(mountKey, generation)`, `setIcmGitSync(mountKey, sync, generation)`, `startGitConflictSession(mountKey, generation)` (generated in `ash_rpc.ts` by Task 4); push `git_status` `%{"repos": [...]}` with snake_case string keys; navigation convention `goto('/chat?session=' + id)` (`routes/+page.svelte:127-144`).
- Produces:
  - `type GitRepoStatus = { mountKey: string; icmName: string; mode: string; state: string; reason: string | null; branch: string | null; ahead: number; behind: number; dirty: boolean; lastSyncAt: string | null; lastError: string | null; conflictSessionId: string | null }`
  - `gitStore` (class `GitStore`): `repos: GitRepoStatus[]` (`$state`), `byMountKey(key)`, `attention(key): boolean` (state ∈ diverged|blocked_local|merge_in_progress), `refresh(generation)`, `handleGitStatus(payload)`, `onGitStatus(listener): () => void` (unsubscribe closure, mail-store pattern `mail.svelte.ts:1286`).
  - `wireGitEvents(channel)` exported from the store module, idempotent flag like `mailEventsWired`.
  - `normalizeGitRepoStatus(raw: unknown): GitRepoStatus | null` — snake keys primary, camel tolerated (the `pick()` dual-read pattern from `today/cockpit.ts:162-179`); drops rows missing `mount_key`/`state`.
  - `gitAttentionText(repo): string` — e.g. `"workspace: local and remote diverged (1 ahead / 2 behind)"`, blocked_local ⇒ `"local edits block sync"`, merge_in_progress ⇒ `"unfinished merge in the working tree"`.

- [ ] **Step 1: Write failing store/normalizer tests** (vitest): normalizer accepts a snake-keyed row and camel-keyed row, rejects junk; store `handleGitStatus` replaces rows sorted by mountKey; `attention()` true only for the three conflict states; `onGitStatus` fires and unsubscribes. Run `cd frontend && npm run test` → fail.

- [ ] **Step 2: Implement store + wiring.** `client.ts`: four wrappers via `runRpc`/`wrapChannelCall` convention (`client.ts:377-392, 900-907`) with fields consts (`['repos']`, `['started']`, `['saved']`, `['sessionId', 'routed']`); add `git: ['repos' /* raw array — see cockpit note */]`—actually for cockpit just append `'git'` to the cockpitToday field selection list (`client.ts:571-602`) as an untyped array field. `socket.ts`: add `GitStatusPush = { repos: Record<string, unknown>[] }` + `channel.on('git_status', …)` typing. `icm.svelte.ts`: `wireGitEvents(channel)` beside `wireMailEvents` (`icm.svelte.ts:657`). Store refreshes on wire + push-driven thereafter.

- [ ] **Step 3: Today page.** `today/cockpit.ts`: add `git: GitRepoStatus[]` to `CockpitToday`, normalize via `normalizeGitRepoStatus`, export `gitAttentionText`. `+page.svelte`: new section modeled EXACTLY on the schedule-notices block (`+page.svelte:348-382`) — overline "Git", one row per attention repo: warn dot, `gitAttentionText(repo)`, and a small outline Button (reuse the Button component `ScheduleRow.svelte:212` imports) labeled `Resolve with agent` / `Open session` (when `conflictSessionId` non-null):

```svelte
{#if gitAttention.length > 0}
  <section class="mt-8">
    <p class="text-overline mb-2">Git</p>
    <ul class="flex flex-col">
      {#each gitAttention as repo (repo.mountKey)}
        <li class="flex items-center gap-2 py-1.5 pr-2">
          <span class="bg-warn-ink size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
          <span class="text-ink-body min-w-0 flex-1 text-[13px]">{gitAttentionText(repo)}</span>
          <Button variant="outline" size="sm" disabled={resolving === repo.mountKey}
            onclick={() => void resolveConflict(repo)}>
            {repo.conflictSessionId ? 'Open session' : 'Resolve with agent'}
          </Button>
        </li>
      {/each}
    </ul>
  </section>
{/if}
```

`resolveConflict`: if `conflictSessionId` → `goto('/chat?session=' + repo.conflictSessionId)`; else `api.startGitConflictSession(repo.mountKey, workspaceStore.generation ?? 0)` → on ok `void recentSessionsStore.refresh(); goto('/chat?session=' + data.sessionId)`; on error show the message inline (small `text-warn-ink` line under the row) and `void refresh()`. Subscribe in `onMount` beside the mail/icm subscriptions (`+page.svelte:66-82`): `const unsubGit = gitStore.onGitStatus(() => void refresh());`.

- [ ] **Step 4: Sidebar badge + modal.** `IcmProjects.svelte`: in the row (`:153-234`), before the degraded/folder slot, when `gitStore.attention(group.mountKey)` render `<span class="bg-warn-ink size-1.5 shrink-0 rounded-full" title="Git sync needs attention" aria-label="Git sync needs attention"></span>`. Add dropdown item `Git sync…` (visible when `gitStore.byMountKey(group.mountKey)` exists) opening `GitSyncModal` — scaffold the modal on `HarnessSettingsModal.svelte` (same Dialog primitives): status line (`state`, branch, ahead/behind, lastSyncAt, lastError), three-radio mode picker (Off / Pull only / Full sync, one-line descriptions from the spec) calling `setIcmGitSync` on change (optimistic disable while saving), `Sync now` button → `gitSyncNow`, and the same Resolve/Open button as Today when in a conflict state.

- [ ] **Step 5: Run** — `npm run test`, `npm run check`. Then browser-verify against the dev rig (launch.json `backend-dev` isolated posture; see docs/testing/browser-test-plan.md): fabricate a diverged repo in a scratch ICM, watch the Today row + badge appear, click Resolve, confirm the chat opens with the briefing as the first user message.

- [ ] **Step 6: Commit**

```bash
git add frontend/src
git commit -m "feat(git): frontend sync status — store, Today attention rows, sidebar badge, per-ICM modal"
```

---

### Task 6: Docs + live acceptance checklist

**Files:**
- Create: `docs/superpowers/acceptance/2026-07-30-icm-git-sync.md`
- Modify: `docs/ARCHITECTURE.md` (short git-sync subsystem note beside the mail/calendar engine sections)

**Interfaces:** none produced; consumes everything shipped above.

- [ ] **Step 1: Acceptance doc** — mirror the structure of `docs/superpowers/acceptance/2026-07-18-calendar-feeds.md` (sections, Observed columns). Sections:
  - **A. Real repo, pull mode (default)**: A1 mount the real `workspace` ICM → doctor `git_sync` ok, sidebar quiet; A2 push from another clone → within a poll (or Sync now) the ICM fast-forwards; A3 dirty local file + remote change to same file → blocked_local row on Today.
  - **B. Full mode**: B1 flip to Full in the modal → edit a file → auto-commit `valea sync:` lands on the remote within the quiet window + pass; B2 gitignored `secrets/` file never committed.
  - **C. Conflict handoff**: C1 manufacture divergence → Today row + badge; C2 click Resolve with agent → session opens in that ICM, briefing is the first user message, agent reconciles + pushes; C3 next pass clears row/badge without restart; C4 re-click while session lives → routed to the same session.
  - **D. Failure/doctor**: D1 unreachable remote → state error, doctor shows fetch failure, no agent notice; D2 packaged desktop app (Tauri): fetch over ssh works or doctor shows the auth hint (ssh-agent env caveat).
- [ ] **Step 2: ARCHITECTURE.md** — one short paragraph: per-workspace `Valea.Git.Engine`, derived-state/no-durable-files posture, held-means-held, conflict → agent handoff via `initial_prompt`, modes table.
- [ ] **Step 3: Full gates** — `cd backend && mix test`, `cd frontend && npm run test && npm run check`, `just codegen` fresh (no diff).
- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "docs(git): acceptance checklist + architecture note for ICM git sync"
```

---

## Plan self-review notes (kept for the executor)

- Spec coverage: scope/detection (T1 detect + T2 doctor), config + block scalars (T2), engine/pass/holds/backoff/watcher-debounce (T3), notices-as-derived-state + cockpit + channel (T4), handoff RPC + briefing + session_id routing (T3/T4), UI surfaces (T5), doctor (T2), testing + acceptance (all + T6). The spec's "notice records session_id" is implemented as engine-held `conflict_session_id` + RPC routing — same observable behavior, no storage; the spec's cockpit-notices phrasing maps to the derived `"git"` block + attention rows.
- Deliberate deviations from spec wording, all behavior-preserving: none functional. `blocked_local` still triggers the same one-click handoff.
- Type consistency spot-checks: `status()` keys match between engine (atom), channel/cockpit (stringified snake), FE normalizer (snake primary); `conflict_handoff` return consumed field-for-field by `Api.Git.route/3`; `Cli.run` opts `timeout_ms` used by `Repo.fetch/push`.
- Known verify-at-execution points (called out inline): exact `write_icms` arity, `ProcessRuntime.start/2` handle shape (doctor's `probe` is authoritative), `Env.minimal/0` shape, Api resource boilerplate from `Api.Skills`, vitest file layout.
