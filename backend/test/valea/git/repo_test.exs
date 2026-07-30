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
    assert {:ok, %{local_sha: committed}} = Repo.read_state(fx.work, Cli)
    # Nothing staged: `:ok` with no commit made. Decided by `diff --cached`'s
    # exit code, so it holds on a host whose git speaks German.
    assert :ok = Repo.commit_all(fx.work, "valea sync: empty", Cli)
    assert {:ok, %{local_sha: ^committed}} = Repo.read_state(fx.work, Cli)
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
