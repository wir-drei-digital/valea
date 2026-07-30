defmodule Valea.Git.Repo do
  @moduledoc """
  Derives repo state and performs the four sanctioned mutations (`commit_all`,
  `fetch`, `ff_merge`, `push`) via a Cli module. Valea never merges (non-ff),
  rebases, or force-pushes — those verbs deliberately do not exist here, so no
  future caller can reach for one: anything that could rewrite or invent
  history is the user's to do in their own git client.

  Every function takes the Cli module explicitly (`Valea.Git.Cli` in
  production, a stub implementing its behaviour in tests) — the one seam that
  keeps callers testable without spawning git.
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

  @doc """
  Classifies a directory WITHOUT shelling out — the doctor and the engine call
  this on every pass, so it stays a filesystem question.

  `:repo` only at a real repo root: a `.git` FILE means a linked worktree or
  submodule whose gitdir lives outside the ICM, and a directory nested inside
  someone else's repo would make Valea commit files it was never pointed at.
  Both are named rather than silently treated as `:none`.
  """
  @spec detect(String.t()) :: :repo | {:unsupported, String.t()} | :none
  def detect(root) do
    dot_git = Path.join(root, ".git")

    cond do
      File.dir?(dot_git) ->
        :repo

      File.regular?(dot_git) ->
        {:unsupported,
         ".git is a file (linked worktree or submodule) — its gitdir lives outside this ICM"}

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

  @doc """
  One snapshot of the repo: branch, upstream, cleanliness, and the ahead /
  behind counts against the last fetch. Reads only — `ahead` and `behind` are
  as stale as the last `fetch/2`, which is the caller's decision to make.
  """
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
         conflicted: Enum.any?(lines, &(status_code(&1) in @conflict_codes)),
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

  # A half-finished merge/rebase/cherry-pick is git's own state file, not
  # something `status --porcelain` reports in a machine-stable way.
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

  @doc """
  Stages everything and commits. "Nothing to commit" is `:ok`, not an error:
  a sync pass over an unchanged ICM is a success with no commit in it.
  """
  @spec commit_all(String.t(), String.t(), module()) ::
          :ok | {:error, {:commit_failed, String.t()}}
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

  @doc """
  Fast-forward to the upstream, or fail. `--ff-only` is the whole point: if
  the histories diverged, git refuses and the ICM is left exactly as it was
  for the user to resolve — Valea does not author merge commits.
  """
  @spec ff_merge(String.t(), module()) :: :ok | {:error, {:ff_failed, String.t()}}
  def ff_merge(root, cli) do
    case cli.run(root, ["merge", "--ff-only", "@{u}"], []) do
      {:ok, %{exit: 0}} -> :ok
      {:ok, %{output: out}} -> {:error, {:ff_failed, out}}
      {:error, reason} -> {:error, {:ff_failed, inspect(reason)}}
    end
  end

  @doc """
  Pushes the current branch to its upstream. A rejection is distinguished
  from a failure because they need different words from the UI: rejected
  means "fetch and try again", failed means "something is wrong".
  """
  @spec push(String.t(), module()) :: :ok | {:error, term()}
  def push(root, cli) do
    case cli.run(root, ["push", "--quiet"], timeout_ms: @network_timeout_ms) do
      {:ok, %{exit: 0}} ->
        :ok

      {:ok, %{output: out}} ->
        if out =~ "[rejected]" or out =~ "non-fast-forward",
          do: {:error, {:push_rejected, out}},
          else: {:error, {:push_failed, out}}

      {:error, reason} ->
        {:error, {:push_failed, inspect(reason)}}
    end
  end

  @doc "Commit subjects in `range` (e.g. `\"@{u}..HEAD\"`), newest first, at most `cap`."
  @spec log_subjects(String.t(), String.t(), pos_integer(), module()) :: [String.t()]
  def log_subjects(root, range, cap, cli) do
    case cli.run(root, ["log", "--format=%s", "--max-count=#{cap}", range], []) do
      {:ok, %{exit: 0, output: out}} -> String.split(out, "\n", trim: true)
      _error -> []
    end
  end

  @doc "Paths with pending changes, conflicted ones first, at most `cap`."
  @spec changed_files(String.t(), pos_integer(), module()) :: [String.t()]
  def changed_files(root, cap, cli) do
    case cli.run(root, ["status", "--porcelain"], []) do
      {:ok, %{exit: 0, output: out}} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.sort_by(&(status_code(&1) in @conflict_codes), :desc)
        |> Enum.map(&String.slice(&1, 3..-1//1))
        |> Enum.take(cap)

      _error ->
        []
    end
  end

  # The two-letter XY status of a `--porcelain` line. Guarded rather than a
  # bare `binary_part/3`: a malformed line must not crash a state read.
  defp status_code(line) when byte_size(line) >= 2, do: binary_part(line, 0, 2)
  defp status_code(_short), do: ""

  defp run0(root, args, cli) do
    case cli.run(root, args, []) do
      {:ok, %{exit: 0, output: out}} -> {:ok, out}
      {:ok, %{output: out}} -> {:error, {:git_error, out}}
      {:error, reason} -> {:error, reason}
    end
  end
end
