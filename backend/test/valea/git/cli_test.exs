defmodule Valea.Git.CliTest do
  use ExUnit.Case, async: false

  alias Valea.Git.Cli

  if not GitFixtures.git_available?(), do: @moduletag(:skip)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vgitcli-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Mutates the REAL process environment (hence `async: false`): the point is
  # that `Env.minimal/0` reads it, so a hostile locale must be observed
  # exactly the way a German-locale host would present one.
  defp with_locale(value, fun) do
    previous = for k <- ~w(LC_ALL LANG LC_CTYPE), do: {k, System.get_env(k)}

    try do
      for k <- ~w(LC_ALL LANG LC_CTYPE), do: System.put_env(k, value)
      fun.()
    after
      for {k, v} <- previous do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end
  end

  test "git_env pins LC_ALL=C over whatever the host locale says" do
    assert Cli.git_env()["LC_ALL"] == "C"
    assert Cli.git_env()["GIT_TERMINAL_PROMPT"] == "0"

    with_locale("de_DE.UTF-8", fn ->
      assert Cli.git_env()["LC_ALL"] == "C"
    end)
  end

  test "git output stays English under a non-C host locale", %{dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    GitFixtures.git!(repo, ["init", "--initial-branch=main", "."])
    GitFixtures.identity!(repo)
    GitFixtures.write_commit!(repo, "seed.md", "seed", "seed")

    with_locale("de_DE.UTF-8", fn ->
      assert {:ok, %{exit: exit, output: out}} = Cli.run(repo, ["commit", "-m", "empty"], [])
      # The exit code is the contract; the prose is what `Repo.commit_all`'s
      # fallback reads, and it must not turn into "nichts zu committen".
      assert exit != 0
      assert out =~ "nothing to commit"
    end)
  end

  test "run reports output and a zero exit for a successful git call", %{dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    GitFixtures.git!(repo, ["init", "--initial-branch=main", "."])

    assert {:ok, %{exit: 0, output: out}} = Cli.run(repo, ["rev-parse", "--is-inside-work-tree"])
    assert String.trim(out) == "true"
  end
end
