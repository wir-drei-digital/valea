# ICM git sync — live acceptance checklist

Manual checks executed by the user AFTER merge, against a **real remote**
and a **packaged desktop build**. The automated suite covers every pass
rule, hold, backoff and handoff against the `Valea.Git.Cli` seam plus real
`git` over fixture repos (tmp bare "remote" + two clones); this list is the
part only a real network, a real credential path and a real `.app` launch
environment can prove. Spec:
`docs/superpowers/specs/2026-07-30-icm-git-sync-design.md` — read its
**Implementation amendments (2026-07-30)** section first, because three of
the checks below (A3's fingerprint hold, B3's commit-before-hold, C4's
claim protocol) test the amended behavior rather than the original prose.

**A full dev-rig browser pass ran green on 2026-07-30** (worktree backend +
vite, fake agent adapter, fabricated diverged repo): Today attention row,
sidebar dot, the per-ICM modal (status, mode picker, "Sync now"), the yaml
write, the one-click handoff with the briefing as the first user message,
the "Open session" flip and the same-session second click were all
observed. So the purpose of this checklist is narrower than usual: confirm
the same behavior against a **real remote** (real fetch/push, real auth,
real latency, real divergence) and inside the **packaged app**, where the
process environment is not a terminal's. Nothing here is a re-run of the
unit suite.

Conventions: `ICM` = the real git ICM's root on disk (mount root == repo
root), `OTHER` = a second clone of the same remote in a scratch directory,
standing in for "someone else pushed". Fill every **Observed:** line; a
blank one means the check has not run. "Within a poll" means the 5-minute
jittered interval pass — every drill can be forced immediately with **Sync
now** in the ICM's *Git sync…* panel (kebab menu on the ICM row), and doing
so is not cheating except where a check explicitly says to wait.

## Preface: `.valea/` and the .gitignore line

Valea materializes its own namespace into every ICM root it works in —
`.valea/briefing.md` (the tasks/schedules contract, written at session
launch and by the scheduler) and `.valea/task-archive.jsonl` once anything
is archived. Creating a *new* ICM from Valea's template also seeds
`AGENTS.md` / `CONTEXT.md` / a `CLAUDE.md` symlink. On a git ICM all of that
is simply untracked content, so **a freshly mounted repo will show as dirty
the first time a session runs in it**. That is truthful, not a bug, but it
has two consequences worth removing before the drills: in `pull` mode the
dirt is noise on every status read, and in `full` mode `git add -A` will
**commit `.valea/`** unless it is ignored.

Recommended, in the ICM's `.gitignore` (or `.git/info/exclude` if the repo
is shared with people who do not use Valea):

```gitignore
.valea/
```

- [ ] **P1 · The gitignore line is in place.** Add `.valea/` to the ICM's
      ignore rules, then run a session in the ICM (which materializes
      `.valea/briefing.md`) and confirm `git status` is clean.
  - Observed:
- [ ] **P2 · The briefing is honest when it is NOT ignored.** Before adding
      the line (or in a scratch repo), manufacture a conflict and read the
      briefing's "Files needing attention" list: `.valea/` appears there
      when it is part of what blocks the repo. (Observed in the dev rig on
      2026-07-30; re-confirm the wording reads sensibly on a real repo.)
  - Observed:
- [ ] **P3 · `OTHER` clone ready.** `git clone <remote> /tmp/icm-other` and
      confirm it pushes/pulls with the same credentials Valea will use.
  - Observed:

## A — Real repo, pull mode (the default)

- [ ] **A1 · Mount and be quiet.** Mount the real `workspace` ICM (an
      external ICM whose mount root *is* the repo root). Expect: the ICM
      row's kebab menu offers **Git sync…**; the panel shows the branch,
      `Pull only` selected (the default for a detected repo with no `git:`
      block), and `In sync`. Diagnose → the check labelled
      **`<mount key>: git sync`** is **ok** with detail
      `<branch> ↔ <upstream> · mode pull`. Today has **no** Git section and
      the sidebar row has **no** amber dot.
  - Observed:
- [ ] **A2 · Remote work arrives.** Commit and push a file change from
      `OTHER`. Expect: within a poll (or immediately on **Sync now**) the
      ICM fast-forwards — the file content is on disk, `git log` shows the
      remote commit as a plain fast-forward with **no merge commit and no
      local commit of your own**, and the panel's last-sync timestamp
      advances. `pull` mode must not create history.
  - Observed:
- [ ] **A3 · Dirty file in the way → `blocked_local`, and it lifts.** Edit
      a tracked file locally WITHOUT committing, then from `OTHER` commit
      and push a change **to that same file**. Expect, in order:
      1. Next pass: a **Git** section on Today reading
         `<ICM>: local edits block sync`, with a **Resolve with agent**
         button; the sidebar row gets an amber dot. The panel shows
         `Blocked by local edits` and git's own refusal text.
      2. The hold is *learned*, not guessed — it is only entered because
         git actually refused the fast-forward, and your working tree is
         left byte-identical (confirm: your edit is still there, unstaged).
      3. **Held means held.** While the row stands, push a *third* commit
         from `OTHER` and wait through at least one poll: the ahead/behind
         numbers must **not** move — a held repo does no network at all.
      4. Revert (or stash) the blocking edit. Next pass (or **Sync now**):
         the repo re-asks git, fast-forwards, and the row + dot clear
         **without restarting the app** — the hold expires the moment the
         tree stops being the one git ruled on.
      5. The other exit, worth seeing once: instead of reverting, *commit*
         the blocking file. The repo is then behind AND ahead, so the row
         becomes `diverged` (section C) rather than fast-forwarding. Both
         exits keep your edit; neither is Valea choosing for you.
  - Observed:
- [ ] **A4 · Unrelated dirt blocks nothing.** Leave an edit in a file the
      incoming commit does not touch (or an untracked scratch file), then
      push an unrelated change from `OTHER`. Expect a normal
      fast-forward — no `blocked_local` row, dirt untouched. (This is the
      point of not inferring the hold from "behind and dirty": a repo held
      on that guess would never fetch again.)
  - Observed:

## B — Full mode

- [ ] **B1 · Auto-commit and auto-push round trip.** In the panel choose
      **Full sync**. Expect: `WS/config/workspace.yaml`'s `icms:` entry for
      this mount gains `git:` / `sync: full` (check the file — every other
      key in the entry, and any hand-written `instructions:` block scalar,
      must survive the write untouched), and the panel shows the new
      mode with no revert-flicker. Now edit a file in the ICM and wait out
      the quiet window (~2 minutes after the last write). Expect: a commit
      `valea sync: <ISO8601>` lands and is pushed — verify from `OTHER`
      with `git fetch && git log origin/<branch>`. Then repeat with
      **Sync now** instead of waiting, and confirm it fires immediately.
  - Observed:
- [ ] **B2 · Gitignored secrets are never committed.** With `secrets/` in
      the ICM's `.gitignore`, create `secrets/live-check.txt` containing a
      recognizable string. Trigger a full-mode pass. Expect: the file is
      **not** in the resulting commit, **not** on the remote
      (`git log -p` on `OTHER` finds nothing), and `git status` still calls
      it ignored. Confirm the same for `.valea/` if you added the preface's
      line — full mode's `git add -A` respects `.gitignore` and nothing
      else.
  - Observed:
- [ ] **B3 · Dirty *and* behind: the work becomes a commit, then holds.**
      In full mode, edit a file locally and push a different commit from
      `OTHER` before the quiet window elapses. Expect: the pass **commits
      your work first**, then fetches, then finds both sides moved and
      **holds `diverged`** with a Today row. Your work is preserved as a
      commit — nothing is stashed, discarded, merged or rebased, and there
      is no `blocked_local` (that state is pull-mode only).
  - Observed:

## C — Conflict handoff

- [ ] **C1 · Manufacture a divergence.** Commit locally (full mode does
      this for you; in pull mode commit by hand) and push a *different*
      commit from `OTHER`. Expect within a poll: a Today **Git** row
      `<ICM>: local and remote diverged (N ahead / M behind)`, the sidebar
      amber dot, the panel showing `Diverged`. Doctor must still read
      **ok** for this ICM — a held repo is a situation with its own
      surface, not a doctor failure.
  - Observed:
- [ ] **C2 · One click starts the resolver.** Click **Resolve with agent**.
      Expect: a normal visible chat session opens in that ICM titled
      `Git sync conflict — <ICM name>`, and the **first user message** is
      the composed briefing: branch + mode, the ahead/behind counts, the
      local-only and remote-only commit subjects (capped at 10 each), the
      files needing attention (capped at 20), then the resolution
      contract — resolve without losing either side's intent, merge or
      rebase at your judgment, never force-push, never discard silently,
      push when clean, summarize. If the mount's `git:` block carries
      `instructions:`, that prose appears LAST under
      `ICM-specific instructions:`. Let the agent actually resolve and
      push; risky commands stay ask-gated as usual.
  - Observed:
- [ ] **C3 · The button flips to Open session.** As soon as the session is
      running, the same row (Today *and* the panel) reads **Open session**
      instead of *Resolve with agent*. (Live-verified in the dev rig on
      2026-07-30; re-verify here on the real remote.)
  - Observed:
- [ ] **C4 · A second click never starts a second agent.** From another
      window/tab — or by double-clicking — press the button again while the
      first session lives. Expect: you are routed to the **same** session
      id, never a new one. Two agents with write scope in one conflicted
      working tree is the failure this claim protocol exists to prevent, so
      if you can produce two, stop and report it.
  - Observed:
- [ ] **C5 · The row clears itself.** After the agent's push leaves the tree
      clean and level with its upstream, the next pass clears the Today row
      and the sidebar dot **without a restart**, and the panel returns to
      `In sync`. No file anywhere records that a conflict happened — the
      state was derived the whole time.
  - Observed:
- [ ] **C6 · Unfinished merge is handed off the same way.** Leave a merge
      or rebase half-done in the ICM by hand (`git merge <branch>` with a
      real conflict, or a stopped `git rebase`). Expect a Today row
      `<ICM>: unfinished merge in the working tree` and the same one-click
      handoff — including from a conflicted rebase, where HEAD is detached
      (a detached HEAD alone is observe-only, but an unfinished merge wins;
      that ordering is what makes the button reachable here).
  - Observed:

## D — Failure, doctor, and the packaged app

- [ ] **D1 · Unreachable remote is doctor material, not a notice.** Break
      the remote (airplane mode, or point the remote at a host that does
      not answer). Expect: the panel shows `Last sync failed` with git's
      own words, Diagnose's `<mount key>: git sync` check **fails**
      (`last sync failed: …`), and **no Today row and no agent notice
      appears** — fetch/push/auth failures are never agent-actionable.
      Leave it broken for ~20 minutes: the per-repo backoff (1 minute,
      doubling to a 30-minute cap) means later polls stop dialling the dead
      remote and simply repeat the same error over freshly-read local
      facts — the app must not stall, spin, or grow a second row. **Sync
      now** clears the backoff and retries immediately (the error text
      should change or repeat *promptly*, proving the dial happened).
      Restore the network and confirm the next pass returns to ok.
  - Observed:
- [ ] **D2 · Packaged app + ssh-agent.** Install and launch the packaged
      desktop build **from Finder/the launcher, not a terminal** (this is
      the whole point: the dev backend inherits your shell's
      `SSH_AUTH_SOCK`, the `.app` does not). With an ssh remote, expect
      EITHER a clean fetch/push, OR a doctor failure whose remedy names the
      cause: *the packaged app may lack your ssh-agent environment — try
      launching from a terminal, or check the remote's credentials.* A
      silent stall, or a failure with no remedy, is a defect. Note which
      one you got — if auth works from the packaged app on your machine,
      say what supplies it (keychain-backed agent, credential helper,
      https remote).
  - Observed:
- [ ] **D3 · Off and out-of-scope ICMs say so, cheaply.** Three
      short-circuits, each on a different surface — note *where* to look,
      it is not the same place for all three:
      1. **Disabled.** Disable the ICM (kebab → *Disable*). Its sidebar row
         disappears entirely, so Diagnose is no longer reachable for it —
         look instead in **Files → "Check your mounts"** (the *Checking your
         mounts* panel, which fans the doctor over every mount, disabled
         ones included). Expect `<mount key>: git sync` = **unknown**,
         `not checked — this mount is disabled.` Re-enable afterwards.
      2. **Degraded.** Degrade one on purpose: rename the ICM's manifest
         (`mv <ICM>/icm.yaml <ICM>/icm.yaml.bak`), which fails the manifest
         load. The row *stays* in the sidebar with a warning triangle, so
         its kebab → **Diagnose** still works. Expect the git check =
         **unknown**, `not checked — this mount is degraded, so nothing is
         syncing it.` Restore the file and confirm the ICM recovers.
      3. **Mode off.** Set the mode to **Off** in the panel. Expect the
         check = **ok**, `git repository detected — sync is off.`, no
         passes touching the repo, and the Today/sidebar surfaces quiet.
      Also confirm the two genuinely *unsupported* shapes — a folder
      mounted **inside** a repo whose root is outside the mount, and a
      `.git` **file** (linked worktree or submodule) — report
      `Not a syncable repository` with the remedy to mount the repo root.
      A **bare** repo is not one of these: it has no `.git` at all, so it
      reads as `not a git repository — git sync not applicable.` — out of
      scope, not a diagnosed failure.
  - Observed:
- [ ] **D4 · No upstream / detached is observe-only.** On a branch with no
      upstream, expect the doctor failure `branch <b> has no upstream —
      observe-only` with the `git branch --set-upstream-to=…` remedy, no
      sync attempts, and no Today row. Same posture for a detached HEAD
      (with no merge in progress).
  - Observed:
