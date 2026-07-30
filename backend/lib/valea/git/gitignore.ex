defmodule Valea.Git.Gitignore do
  @moduledoc """
  The one edit Valea makes to a user's git repository, and only when a human
  clicks the card that offers it: `.valea/` in the ICM's own `.gitignore`,
  plus the index-only untracking that makes the line mean something for a
  folder git already knows about.

  Valea materializes `.valea/` (briefing, task archive) into every ICM root,
  so a git-backed ICM would otherwise sit permanently "uncommitted".
  `Valea.Git.Repo.commit_all/3` already refuses to STAGE it; this is the
  other half — the repo's own ignore file, which is the user's, so it is
  never written unasked.

  Lives beside `Valea.Git.Repo` rather than inside it on purpose: that
  module's contract is the four sanctioned mutations (`commit_all`, `fetch`,
  `ff_merge`, `push`) and nothing else, and `rm --cached` is a fifth verb —
  index-only and non-destructive, but a verb, and one no engine pass may
  reach for. Here it is reachable only from the consent RPC.
  """

  alias Valea.Git.Repo

  @line ".valea/"
  # Both spellings ignore the directory, so either one already present makes
  # the append a no-op — a second line would be noise in the user's file.
  @equivalents [".valea/", ".valea"]

  @doc """
  Appends `.valea/` to `root`'s `.gitignore`, creating the file if it does
  not exist. Idempotent: a file that already ignores `.valea` (either
  spelling, any position) is left byte-for-byte alone.

  Written through a temp file in the SAME directory plus a rename, so a
  crash mid-write can never leave the user with a truncated `.gitignore` —
  the file governs what git sees, and half of one is worse than none.
  """
  @spec ensure_valea_line(String.t()) :: :ok | {:error, {:gitignore_failed, term()}}
  def ensure_valea_line(root) do
    path = Path.join(root, ".gitignore")

    case read_existing(path) do
      {:ok, text} ->
        if ignores_valea?(text),
          do: :ok,
          else: write_atomic(path, text <> separator(text) <> @line <> "\n")

      {:error, reason} ->
        {:error, {:gitignore_failed, reason}}
    end
  end

  @doc """
  Removes `.valea` from the INDEX (never from disk — `--cached`) when git is
  tracking it, so the freshly written ignore line takes effect for a folder
  that was already committed. Answers whether it actually untracked
  anything.

  In `pull` mode the staged deletion sits there until the user commits it,
  which is theirs to decide; in `full` mode the next pass commits it (the
  `:(exclude).valea` pathspec deliberately does not un-stage what is already
  staged).
  """
  @spec untrack_valea(String.t(), module()) :: {:ok, boolean()} | {:error, :untrack_failed}
  def untrack_valea(root, cli) do
    if Repo.valea_tracked?(root, cli) do
      case cli.run(root, ["rm", "-r", "-q", "--cached", ".valea"], []) do
        {:ok, %{exit: 0}} -> {:ok, true}
        _failed -> {:error, :untrack_failed}
      end
    else
      {:ok, false}
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ignores_valea?(text) do
    text
    |> String.split("\n")
    |> Enum.any?(&(String.trim(&1) in @equivalents))
  end

  # A file whose last line has no newline would otherwise gain `x.valea/` —
  # a pattern that ignores nothing and that the user has to notice to fix.
  defp separator(""), do: ""
  defp separator(text), do: if(String.ends_with?(text, "\n"), do: "", else: "\n")

  defp write_atomic(path, content) do
    tmp = path <> ".valea-tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:gitignore_failed, reason}}
    end
  end
end
