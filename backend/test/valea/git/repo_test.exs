# Git hands back BYTES, not text: a latin-1 commit subject, a path written by
# a tool using another encoding. Both list readers must return something
# `Jason` can encode, because they end up in a conflict briefing that travels
# as an RPC reply.
defmodule Valea.Git.RepoTest.RawBytesCli do
  @moduledoc false
  @behaviour Valea.Git.Cli

  @impl true
  def run(_root, ["log" | _], _opts),
    do: {:ok, %{exit: 0, output: <<"caf", 0xE9, " subject\nplain subject\n">>}}

  def run(_root, ["status", "--porcelain"], _opts),
    do: {:ok, %{exit: 0, output: <<"UU caf", 0xE9, ".md\n M plain.md\n">>}}
end

# Records the argv it was handed and reports success — the only way to assert
# what `push/3` actually asks git to do.
defmodule Valea.Git.RepoTest.ArgvCli do
  @moduledoc false
  @behaviour Valea.Git.Cli

  @impl true
  def run(_root, args, _opts) do
    send(Application.fetch_env!(:valea, :repo_argv_probe), {:argv, args})
    {:ok, %{exit: 0, output: ""}}
  end
end

defmodule Valea.Git.RepoTest do
  use ExUnit.Case, async: false

  alias Valea.Git.{Cli, Repo}
  alias Valea.Git.RepoTest.ArgvCli
  alias Valea.Git.RepoTest.RawBytesCli

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
    assert {:ok, %{local_sha: committed}} = Repo.read_state(fx.work, Cli)
    # Nothing staged: `:ok` with no commit made. Decided by `diff --cached`'s
    # exit code, so it holds on a host whose git speaks German.
    assert :ok = Repo.commit_all(fx.work, "valea sync: empty", Cli)
    assert {:ok, %{local_sha: ^committed}} = Repo.read_state(fx.work, Cli)
    assert :ok = Repo.push(fx.work, "origin/main", Cli)
    GitFixtures.advance_remote!(fx)
    assert :ok = Repo.fetch(fx.work, Cli)
    assert :ok = Repo.ff_merge(fx.work, Cli)
    assert {:ok, %{ahead: 0, behind: 0}} = Repo.read_state(fx.work, Cli)
  end

  # Valea materializes `.valea/` into every ICM root. Both halves of the
  # pathspec matter: an auto-commit must never ADD Valea's own working data
  # to the user's history, and it must still commit the STAGED DELETION the
  # ".valea/ → .gitignore" offer leaves behind (`git rm -r --cached`) — the
  # user consented to that untracking, so a pass must not quietly drop it.
  test "commit_all never adds .valea, but does commit a staged deletion of it", %{fx: fx} do
    File.mkdir_p!(Path.join(fx.work, ".valea"))
    File.write!(Path.join(fx.work, ".valea/briefing.md"), "valea's own working data")
    File.write!(Path.join(fx.work, "note.md"), "the user's page")

    assert :ok = Repo.commit_all(fx.work, "valea sync: user work only", Cli)

    assert tracked?(fx.work, "note.md")
    refute tracked?(fx.work, ".valea/briefing.md")
    # Still on disk — excluded from the index, never deleted.
    assert File.exists?(Path.join(fx.work, ".valea/briefing.md"))

    # A repo that already committed `.valea` before Valea ever saw it: the
    # offer untracks it, and the next full-mode pass has to commit that.
    GitFixtures.git!(fx.work, ["add", "-f", ".valea"])
    GitFixtures.git!(fx.work, ["commit", "-m", "user committed .valea"])
    assert tracked?(fx.work, ".valea/briefing.md")

    GitFixtures.git!(fx.work, ["rm", "-r", "-q", "--cached", ".valea"])
    assert :ok = Repo.commit_all(fx.work, "valea sync: staged removal", Cli)

    refute tracked?(fx.work, ".valea/briefing.md")
    assert File.exists?(Path.join(fx.work, ".valea/briefing.md"))
  end

  # The steady state AFTER the offer is taken, and the reason `commit_all/3`
  # picks its `add` argv rather than hardcoding one: an exclude pathspec makes
  # git exit non-zero over any IGNORED path it names, so a repo carrying
  # `.valea/` in its `.gitignore` would fail every single pass with nothing
  # wrong. It still must not stage `.valea` — an ignored folder is not swept
  # up by a plain `add -A` either.
  test "commit_all keeps working once .valea is ignored, and still leaves it out", %{fx: fx} do
    File.write!(Path.join(fx.work, ".gitignore"), ".valea/\n")
    File.mkdir_p!(Path.join(fx.work, ".valea"))
    File.write!(Path.join(fx.work, ".valea/briefing.md"), "valea's own working data")
    File.write!(Path.join(fx.work, "note.md"), "the user's page")

    assert :ok = Repo.commit_all(fx.work, "valea sync: ignored already", Cli)

    assert tracked?(fx.work, "note.md")
    assert tracked?(fx.work, ".gitignore")
    refute tracked?(fx.work, ".valea/briefing.md")
    assert {:ok, %{dirty: false}} = Repo.read_state(fx.work, Cli)
  end

  test "valea_ignored? / valea_tracked? answer the offer's two questions", %{dir: dir, fx: fx} do
    File.mkdir_p!(Path.join(fx.work, ".valea"))
    File.write!(Path.join(fx.work, ".valea/briefing.md"), "x")

    assert Repo.valea_ignored?(fx.work, Cli) == false
    assert Repo.valea_tracked?(fx.work, Cli) == false

    File.write!(Path.join(fx.work, ".gitignore"), "node_modules/\n.valea/\n")
    assert Repo.valea_ignored?(fx.work, Cli) == true

    # A TRACKED path reads NOT ignored even with the rule present — git's
    # `check-ignore` consults the index, because an ignore rule does nothing
    # for a file git already has. That is the answer the offer wants: the
    # card keeps appearing until the untracking half is done too.
    GitFixtures.git!(fx.work, ["add", "-f", ".valea"])
    assert Repo.valea_tracked?(fx.work, Cli) == true
    assert Repo.valea_ignored?(fx.work, Cli) == false

    GitFixtures.git!(fx.work, ["rm", "-r", "-q", "--cached", ".valea"])
    assert Repo.valea_tracked?(fx.work, Cli) == false
    assert Repo.valea_ignored?(fx.work, Cli) == true

    # Not a repo: git cannot answer, and "don't know" must not read as "no"
    # — a `false` is what makes the UI offer to write the line.
    plain = Path.join(dir, "plain-for-ignore")
    File.mkdir_p!(plain)
    assert Repo.valea_ignored?(plain, Cli) == nil
    assert Repo.valea_tracked?(plain, Cli) == false
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

  test "remotes: named for a clone, empty for a local-only repo", %{dir: dir, fx: fx} do
    assert Repo.remotes(fx.work, Cli) == ["origin"]

    lone = Path.join(dir, "lone")
    File.mkdir_p!(lone)
    GitFixtures.git!(lone, ["init", "--initial-branch=main", "."])
    assert Repo.remotes(lone, Cli) == []
  end

  # The argv is the contract: a bare `git push` is configuration-driven
  # (`push.default = matching` pushes every branch whose name exists on the
  # remote, `remote.pushDefault` redirects it), and the spec's scope is the
  # checked-out branch and its configured upstream — nothing else.
  test "push names the upstream's remote and the checked-out branch, and nothing else" do
    Application.put_env(:valea, :repo_argv_probe, self())
    on_exit(fn -> Application.delete_env(:valea, :repo_argv_probe) end)

    assert :ok = Repo.push("/nowhere", "origin/main", ArgvCli)
    assert_received {:argv, ["push", "--quiet", "origin", "HEAD:main"]}

    # The remote is DERIVED, never assumed to be `origin` — a clone tracking a
    # fork must push to the fork. A remote name cannot contain a slash, so
    # everything after the first one is the branch.
    assert :ok = Repo.push("/nowhere", "fork/feature/nested", ArgvCli)
    assert_received {:argv, ["push", "--quiet", "fork", "HEAD:feature/nested"]}

    assert :ok = Repo.push("/nowhere", nil, ArgvCli)
    assert_received {:argv, ["push", "--quiet", "origin", "HEAD"]}
  end

  test "a push the remote has moved past is classified as rejected, not failed", %{fx: fx} do
    GitFixtures.advance_local!(fx)
    GitFixtures.advance_remote!(fx)

    assert {:error, {:push_rejected, out}} = Repo.push(fx.work, "origin/main", Cli)
    assert out != ""
  end

  # Invalid UTF-8 anywhere in these two lists reaches `Jason` through the
  # conflict briefing's `initial_prompt`, where it RAISES. Scrubbed at the
  # reader, so no caller has to remember.
  test "log_subjects and changed_files return valid UTF-8 for non-UTF-8 git output" do
    assert [first, "plain subject"] = Repo.log_subjects("/nowhere", "@{u}..HEAD", 10, RawBytesCli)
    assert String.valid?(first)
    assert first =~ "caf"
    assert first =~ <<0xFFFD::utf8>>

    assert [conflicted, "plain.md"] = Repo.changed_files("/nowhere", 20, RawBytesCli)
    assert String.valid?(conflicted)
    assert conflicted =~ ".md"
    assert Enum.all?([conflicted, "plain.md"], &String.valid?/1)
  end

  defp tracked?(repo, rel),
    do: GitFixtures.git!(repo, ["ls-files", "--", rel]) |> String.trim() != ""
end
