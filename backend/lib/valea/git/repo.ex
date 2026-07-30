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

  # Scrubbed for the same reason the two list readers below are: a git REF is
  # a byte string, not text, and both of these land on a status row that is
  # JSON-encoded on three surfaces.
  defp read_branch(root, cli) do
    case cli.run(root, ["symbolic-ref", "--short", "-q", "HEAD"], []) do
      {:ok, %{exit: 0, output: out}} -> out |> scrub() |> String.trim()
      _detached_or_error -> nil
    end
  end

  defp read_upstream(root, cli) do
    case cli.run(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], []) do
      {:ok, %{exit: 0, output: out}} -> out |> scrub() |> String.trim()
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

  @doc """
  The repository's configured remote names, newline-split. `[]` means a
  LOCAL-ONLY repository — one that was `git init`ed and never given a remote,
  which is a deliberate shape rather than a misconfiguration, and the one
  thing that tells "nothing to sync against" from "a branch whose upstream
  was never set" (`Valea.Mounts.Doctor` is the only caller, and the
  distinction is the difference between two different sentences it says).

  A failure also reads `[]`: the caller reaches this only after a successful
  state read, and both answers put it on the same observe-only branch.
  """
  @spec remotes(String.t(), module()) :: [String.t()]
  def remotes(root, cli) do
    case cli.run(root, ["remote"], []) do
      {:ok, %{exit: 0, output: out}} -> String.split(out, "\n", trim: true)
      _error -> []
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
  Is `.valea` ignored by this repo's ignore rules? `nil` when git could not
  answer at all (`check-ignore` exits 128 on a broken repo, and "I don't
  know" must not read as "no" — the UI offers to write a `.gitignore` line
  on a `false`).

  A pathname question, not a filesystem one: `check-ignore` answers for a
  path whether or not it exists, which is what makes this safe to ask on
  every pass regardless of whether Valea has materialized `.valea/` yet.

  It DOES consult the index, though, and that is the reading the offer
  wants: a `.valea` git already tracks reads `false` even when the ignore
  line is already there, because the rule does nothing for a tracked path.
  The card therefore keeps offering until the untracking half is done too,
  instead of going quiet over a repo that is still committing Valea's
  working data every pass.
  """
  @spec valea_ignored?(String.t(), module()) :: boolean() | nil
  def valea_ignored?(root, cli) do
    case cli.run(root, ["check-ignore", "-q", ".valea"], []) do
      {:ok, %{exit: 0}} -> true
      {:ok, %{exit: 1}} -> false
      _unknown -> nil
    end
  end

  @doc """
  Is anything under `.valea` currently TRACKED? An ignore rule does nothing
  for a file git already has in its index, so this is the other half of the
  question the offer asks — a `true` is what turns "add a line" into "add a
  line and untrack".

  A failed read answers `false`: the caller reaches this only to decide
  whether to ALSO run `rm --cached`, and not running it is the conservative
  half (the next pass asks again).
  """
  @spec valea_tracked?(String.t(), module()) :: boolean()
  def valea_tracked?(root, cli) do
    case cli.run(root, ["ls-files", "--", ".valea"], []) do
      {:ok, %{exit: 0, output: out}} -> String.trim(out) != ""
      _error -> false
    end
  end

  @doc """
  Stages everything and commits. "Nothing to commit" is `:ok`, not an error:
  a sync pass over an unchanged ICM is a success with no commit in it.

  That case is decided by an EXIT CODE, never by reading git's prose. `git
  commit` with an empty index exits 1, so before this was exit-code-driven the
  only thing separating "nothing to do" from a real failure was the English
  substring "nothing to commit" — which a German-locale host renders "nichts
  zu committen", turning every sync pass over an unchanged ICM into a
  permanent bogus error. `Valea.Git.Cli.git_env/0` now also pins `LC_ALL=C`,
  so the substring check below survives as a belt-and-braces fallback rather
  than as the mechanism.

  `.valea/` is EXCLUDED from what this stages (`:(exclude)` pathspec, not a
  `.gitignore` write — Valea does not edit a user's repo without being
  asked). Valea materializes that folder into every ICM root (briefing,
  task archive), so a `full`-mode ICM would otherwise carry Valea's own
  working data into the user's history on the first auto-commit, forever.
  The exclusion is about what gets ADDED: a deletion of `.valea` that is
  already STAGED — which is exactly what the "keep it out of git" offer
  leaves behind (`git rm -r --cached`) — is still seen by the staged-diff
  check below and still committed, so the user's consented untracking is
  never silently dropped.
  """
  @spec commit_all(String.t(), String.t(), module()) ::
          :ok | {:error, {:commit_failed, String.t()}}
  def commit_all(root, message, cli) do
    case cli.run(root, add_argv(root, cli), []) do
      {:ok, %{exit: 0}} -> commit_staged(root, message, cli)
      {:ok, %{output: out}} -> {:error, {:commit_failed, out}}
      {:error, reason} -> {:error, {:commit_failed, inspect(reason)}}
    end
  end

  # Which `add` to run — a BRANCH rather than one fixed argv, because git
  # makes the excluded form conditional on the very thing the offer changes:
  # `git add` reports (and exits non-zero over) any IGNORED path an exclude
  # pathspec touches — "the following paths are ignored by one of your
  # .gitignore files" — so on a repo that HAS taken the offer, the excluded
  # form would fail every pass forever, with nothing actually wrong. (An
  # unrelated ignored path, `node_modules/` and friends, does not provoke it:
  # only a path the exclusion itself names.)
  #
  # And there the exclusion buys nothing: a plain `add -A` does not stage an
  # ignored, untracked folder either. It is needed for the repo that has NOT
  # taken the offer, where `.valea/` is ordinary untracked content `add -A`
  # would otherwise sweep into the user's history.
  #
  # The probe is `--no-index`, i.e. the RULES question, deliberately NOT
  # `valea_ignored?/2`'s index-aware one: it is git's ignore rules that decide
  # whether the excluded form errors, and a `.valea` that is both tracked and
  # ignored would answer "not ignored" there and pick the form that fails.
  # A repo git cannot answer for takes the excluded form — the conservative
  # half, since the failure it risks is "no commit this pass", while a plain
  # `add -A` would risk committing `.valea/` for good.
  defp add_argv(root, cli) do
    case cli.run(root, ["check-ignore", "-q", "--no-index", ".valea"], []) do
      {:ok, %{exit: 0}} -> ["add", "-A"]
      _not_ignored_or_unknown -> ["add", "-A", "--", ".", ":(exclude).valea"]
    end
  end

  # `diff --cached --quiet` exits 0 when the index matches HEAD and 1 when it
  # does not — including against an unborn HEAD, where it compares with the
  # empty tree. Unmerged paths count as a difference, so a conflicted repo
  # still reaches `git commit` and still fails there, as it must.
  defp commit_staged(root, message, cli) do
    case cli.run(root, ["diff", "--cached", "--quiet"], []) do
      {:ok, %{exit: 0}} -> :ok
      _staged_or_unknown -> do_commit(root, message, cli)
    end
  end

  defp do_commit(root, message, cli) do
    case cli.run(root, ["commit", "-m", message], []) do
      {:ok, %{exit: 0}} ->
        :ok

      {:ok, %{output: out}} ->
        if out =~ "nothing to commit" or out =~ "nothing added to commit",
          do: :ok,
          else: {:error, {:commit_failed, out}}

      {:error, reason} ->
        {:error, {:commit_failed, inspect(reason)}}
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
  Pushes the checked-out branch to `upstream` (the `remote/branch` string
  `read_state/2` reports), and to nothing else.

  The argv is SPELLED OUT rather than left to a bare `git push`, because a
  bare push is configuration-driven and the configuration is the user's:
  `push.default = matching` pushes every local branch whose name exists on
  the remote, `remote.pushDefault` redirects which remote it goes to, and a
  `remote.<name>.push` refspec can widen it further. The spec's scope is
  "only the checked-out branch and its configured upstream" (§Scope), so that
  is what the command says — `<remote> HEAD:<branch>` — and no config can
  broaden it. `HEAD:` on the left keeps it the CHECKED-OUT branch even if
  that is not the branch the upstream is named after.

  A rejection is distinguished from a failure because they need different
  words from the UI: rejected means "fetch and try again", failed means
  "something is wrong".
  """
  @spec push(String.t(), String.t() | nil, module()) :: :ok | {:error, term()}
  def push(root, upstream, cli) do
    case cli.run(root, ["push", "--quiet" | push_target(upstream)],
           timeout_ms: @network_timeout_ms
         ) do
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

  # `"origin/main"` → `["origin", "HEAD:main"]`. A REMOTE name cannot contain
  # a slash and a branch name can, so the first segment is the remote and
  # everything after it is the branch — which is also why the remote is
  # derived rather than hardcoded to `origin`: a clone whose upstream is
  # `fork/main` must push to `fork`, not to whatever happens to be called
  # `origin`.
  #
  # The no-upstream fallback is a totality guard, not a path in use: a repo
  # without an upstream reads `ahead: 0` (`read_counts/3`), and only `ahead >
  # 0` ever reaches a push.
  defp push_target(upstream) when is_binary(upstream) do
    case String.split(upstream, "/", parts: 2) do
      [remote, branch] when remote != "" and branch != "" -> [remote, "HEAD:" <> branch]
      _unparseable -> ["origin", "HEAD"]
    end
  end

  defp push_target(_absent), do: ["origin", "HEAD"]

  @doc "Commit subjects in `range` (e.g. `\"@{u}..HEAD\"`), newest first, at most `cap`."
  @spec log_subjects(String.t(), String.t(), pos_integer(), module()) :: [String.t()]
  def log_subjects(root, range, cap, cli) do
    case cli.run(root, ["log", "--format=%s", "--max-count=#{cap}", range], []) do
      {:ok, %{exit: 0, output: out}} -> out |> scrub() |> String.split("\n", trim: true)
      _error -> []
    end
  end

  @doc "Paths with pending changes, conflicted ones first, at most `cap`."
  @spec changed_files(String.t(), pos_integer(), module()) :: [String.t()]
  def changed_files(root, cap, cli) do
    case cli.run(root, ["status", "--porcelain"], []) do
      {:ok, %{exit: 0, output: out}} ->
        out
        |> scrub()
        |> String.split("\n", trim: true)
        |> Enum.sort_by(&(status_code(&1) in @conflict_codes), :desc)
        |> Enum.map(&String.slice(&1, 3..-1//1))
        |> Enum.take(cap)

      _error ->
        []
    end
  end

  # THE one place git text that travels as DATA rather than as an error string
  # is made valid UTF-8. Git stores commit messages, ref names and path names
  # as raw BYTES: a latin-1 commit subject, or a filename written by a tool
  # with another encoding, comes back as-is — and these two lists are what
  # `Valea.Git.Briefing` composes into a conflict session's `initial_prompt`,
  # which is JSON-encoded on the RPC reply. Invalid UTF-8 makes `Jason` RAISE
  # there, so an ICM with one oddly-encoded commit could never be handed off.
  #
  # Scrubbed BEFORE the split and the grapheme `String.slice/2` below, so
  # neither has to reason about invalid bytes. Same U+FFFD semantic, and the
  # same `String.valid?/1` fast path, as `Valea.Mail.Account` /
  # `Valea.Mail.HtmlSanitizer` (error strings are scrubbed by
  # `Valea.Git.Engine.describe/1` instead — the other end of the same class).
  defp scrub(out) do
    if String.valid?(out), do: out, else: Valea.Mail.Normalizer.scrub_utf8(out)
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
