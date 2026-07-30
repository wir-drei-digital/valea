defmodule Valea.Git.BriefingTest do
  # Pure function over a details map — no process, no filesystem, no git.
  use ExUnit.Case, async: true

  alias Valea.Git.Briefing

  defp details(overrides \\ %{}) do
    Map.merge(
      %{
        icm_name: "Work",
        branch: "main",
        mode: "full",
        state: "diverged",
        ahead: 2,
        behind: 1,
        local_subjects: ["local: notes", "local: agenda"],
        remote_subjects: ["remote: policy"],
        files: ["local.md", "remote.md"]
      },
      overrides
    )
  end

  describe "compose/2" do
    test "a diverged briefing names the ICM, both counts, every subject and file" do
      text = Briefing.compose(details(), nil)

      assert text =~ ~s(the "Work" ICM)
      assert text =~ "branch main"
      assert text =~ "sync mode full"
      assert text =~ "2 ahead / 1 behind"
      assert text =~ "Local-only commits (2):"
      assert text =~ "Remote-only commits (1):"
      assert text =~ "- local: notes"
      assert text =~ "- local: agenda"
      assert text =~ "- remote: policy"
      assert text =~ "- local.md"
      assert text =~ "- remote.md"
    end

    test "states the rules Valea will not have broken on its behalf" do
      text = Briefing.compose(details(), nil)

      assert text =~ "Never force-push. Never discard changes silently."
      assert text =~ "Valea holds and never merges."
      assert text =~ "git log --oneline --left-right @{u}...HEAD"
    end

    test "each conflict-class state gets its own situation line" do
      assert Briefing.compose(details(%{state: "blocked_local"}), nil) =~
               "uncommitted local edits block the fast-forward"

      assert Briefing.compose(details(%{state: "merge_in_progress"}), nil) =~
               "a merge/rebase was left unfinished"

      # A state outside the conflict class still composes rather than raising:
      # the briefing is derived from a live re-read, which can always have
      # moved on between the status row and the handoff.
      assert Briefing.compose(details(%{state: "ok"}), nil) =~ "needs reconciliation"
    end

    test "a detached HEAD is named rather than rendered as nil" do
      assert Briefing.compose(details(%{branch: nil}), nil) =~ "branch detached"
    end

    test "per-ICM instructions are appended under their own header" do
      text = Briefing.compose(details(), "Merge, never rebase.\nAsk before deleting pages.")

      assert text =~
               "ICM-specific instructions:\nMerge, never rebase.\nAsk before deleting pages."

      # After Valea's own rules, never before them.
      assert :binary.match(text, "Never force-push") < :binary.match(text, "ICM-specific")
    end

    test "no instructions means no header at all" do
      refute Briefing.compose(details(), nil) =~ "ICM-specific"
    end

    test "empty lists render as (none) rather than a blank section" do
      text =
        Briefing.compose(
          details(%{local_subjects: [], remote_subjects: [], files: [], ahead: 0, behind: 0}),
          nil
        )

      assert text =~ "Local-only commits (0):\n- (none)\n"
      assert text =~ "Remote-only commits (0):\n- (none)\n"
      assert text =~ "Files needing attention:\n- (none)\n"
    end
  end
end
