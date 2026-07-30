defmodule GitFixtures do
  @moduledoc """
  Builds throwaway git topologies for git-engine tests: a bare "remote" plus
  clones that can be pushed independently to fabricate ahead / behind /
  diverged / dirty / conflicted states. Test-only; uses System.cmd directly.

  Two rules make the topologies reliable:

    * every fixture git call goes through `git!/2`, which pins an isolated
      config (no global/system gitconfig, no terminal prompt) and asserts a
      zero exit — a fixture that silently half-applied is worse than a crash;
    * each clone gets its identity written to its OWN `.git/config`, because
      the commits made *by the code under test* run through
      `Valea.Git.Cli`, which deliberately does not inject a git identity
      (production must use the user's). Without this, `commit_all` would pass
      only on machines that happen to have a global one.
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
    identity!(work)
    write_commit!(work, "seed.md", "seed", "seed")
    git!(work, ["push", "-u", "origin", "main"])
    git!(dir, ["clone", bare, other])
    identity!(other)
    git!(other, ["checkout", "main"])
    git!(other, ["branch", "--set-upstream-to=origin/main", "main"])
    %{bare: bare, work: work, other: other}
  end

  @doc """
  Writes a committer identity into `repo`'s own config. Repo-local, so it
  applies to git invocations that do NOT carry this module's `@env` — namely
  the ones the code under test makes.
  """
  def identity!(repo) do
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    :ok
  end

  def write_commit!(repo, rel, content, msg) do
    path = Path.join(repo, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", msg])
  end

  @doc """
  Advance the remote from `other` so `work` is behind by one commit touching
  `rel`.

  `other` is re-synced to the remote first: a test may have pushed from
  `work` since the last call, and pushing a stale `other` would be rejected
  non-fast-forward — a fixture failure masquerading as a code failure.
  """
  def advance_remote!(%{other: other}, rel \\ "remote.md", content \\ "remote change") do
    git!(other, ["fetch", "origin"])
    git!(other, ["reset", "--hard", "origin/main"])
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

  @doc """
  Leave `work` mid-REBASE with conflict markers. Same shape as `conflict!/1`
  with one difference that is the entire point: a rebase replays commits onto
  the upstream, so while it is stopped at a conflict HEAD is DETACHED — there
  is no current branch to read. A classifier that asks "is there a branch?"
  before "is a merge/rebase running?" calls this repo `detached` and never
  offers to resolve it.
  """
  def rebase_conflict!(%{work: work} = fx) do
    write_commit!(work, "clash.md", "local version", "local clash")
    advance_remote!(fx, "clash.md", "remote version")
    git!(work, ["fetch", "origin"])

    {_out, _code} =
      System.cmd("git", ["-C", work, "rebase", "origin/main"], env: @env, stderr_to_stdout: true)

    :ok
  end
end
