defmodule Valea.Git.Briefing do
  @moduledoc """
  Composes the deterministic conflict briefing sent as the resolution
  session's first user message.

  Deterministic and pure on purpose: the same repo state always produces the
  same words, so what the agent is asked to do can be read (and reviewed) off
  the status row without launching anything. Valea states the situation and
  the rules it will not break — never force-push, never discard, never
  silently merge on the user's behalf — and leaves the judgement call to the
  session.

  The per-ICM `instructions` (the user's free text from the mount's `git:`
  block) are appended LAST, after Valea's own rules, so they read as this
  ICM's house style on top of the invariants rather than as a licence to
  replace them.
  """

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
    do:
      "local and remote have both moved (#{d.ahead} ahead / #{d.behind} behind) — Valea holds and never merges."

  defp situation(%{state: "blocked_local"}),
    do: "the remote moved but uncommitted local edits block the fast-forward."

  defp situation(%{state: "merge_in_progress"}),
    do:
      "a merge/rebase was left unfinished in the working tree (conflict markers may be present)."

  defp situation(_other), do: "the repository needs reconciliation."

  defp bullet_list([]), do: "- (none)\n"
  defp bullet_list(items), do: Enum.map_join(items, "", &"- #{&1}\n")

  defp per_icm(nil), do: ""
  defp per_icm(text), do: "\nICM-specific instructions:\n#{text}\n"
end
