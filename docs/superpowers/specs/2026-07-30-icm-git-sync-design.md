# ICM Git Sync — State, Auto-Sync, Conflict → Agent Handoff

**Date:** 2026-07-30
**Status:** Approved (design). Pending implementation plan.

## Goal

Some ICMs are git repositories (e.g. Daniel's `workspace`). Today Valea is
git-blind: nothing syncs them, nothing notices divergence, and a conflicted
repo just sits there. This spec gives Valea:

1. **State** — per-ICM git status (branch, dirty, ahead/behind, held),
   derived live from the repo, visible in the UI.
2. **Sync** — deterministic auto-sync where it is safe (fetch, fast-forward,
   opt-in auto-commit + push). Valea never merges, rebases, or force-pushes.
3. **Conflict handoff** — when the repo diverges or a merge is left half
   done, a notice appears whose button starts a new agent session in that
   ICM with a composed conflict briefing as the first user message. The
   agent — not Valea — resolves the conflict.

Fits the standing philosophy: "LLM only reads, fixed code decides" for the
routine path; the agent handles exactly the part that needs judgment.

## Decisions settled with Daniel (2026-07-30)

- **Valea's git role: auto-sync when safe.** Fetch + fast-forward
  unattended; divergence is never resolved by Valea — hold and notify.
- **One per-ICM sync mode, not separate knobs:** `full` (auto-commit +
  auto-push, notes-style ICMs), `pull` (fetch + ff only — default for
  detected git ICMs), `off`. Auto-push follows auto-commit; no independent
  flags.
- **Handoff is one click:** the notice button starts the session
  immediately with the briefing as the first user message (existing
  `create_agent_session` + `initial_prompt` path). No prefilled composer.
- **Architecture: dedicated git engine** (Mail.Engine shape), not
  scheduler-payload reuse, not agent-does-everything.

## Scope and detection

A mount participates when it is an **external ICM mount whose mount root
contains a `.git` directory** (mount root == repo root). Fail-closed
exclusions, each a doctor note rather than silence:

- **Mount inside a repo but not at its root** → git features off. Valea
  will not run git against a repo root outside the mount boundary
  (containment; same posture as `Valea.Paths.resolve_real`).
- **`.git` file** (linked worktree, submodule) → off. The real gitdir lives
  outside the mount.
- **Detached HEAD / no upstream on the current branch** → observe-only:
  status is shown, no sync. (Branch switching is the user's/agent's
  business; Valea follows whatever is checked out.)
- Bare repos, submodule recursion, multiple remotes beyond the current
  branch's upstream: out of scope. Only the checked-out branch and its
  configured upstream are synced.

## Config

Per-mount `git:` block in the existing config-truth mount entry in
`workspace.yaml`:

```yaml
git:
  sync: pull        # full | pull | off; absent => pull for detected repos
  instructions: |   # optional prose appended to the conflict briefing
    Never rebase; merge and keep both versions of notes files.
```

- Detected git ICMs default to `pull` — safe (nothing published, no history
  written). `full` is deliberate opt-in; `off` opts out.
- `instructions` is freeform prose (agent-native; per-ICM policy lives with
  the ICM's other config).
- A small mode control in the ICM project settings UI writes this block;
  hand-editing the yaml stays first-class.

**No new durable state files.** The repo is the file-first truth; ahead/
behind/dirty/held is re-derived from git every pass. Restarts lose nothing;
there is no sync ledger to corrupt.

## Engine

`Valea.Git.Engine` — one GenServer per workspace under the workspace
runtime supervisor (Mail.Engine shape). All git invocations go through a
thin **`Valea.Git.Cli`** seam: system `git` binary, explicit repo path
(`-C`), per-command timeout, capped output, environment inherited so
ssh-agent / credential helpers work. The seam is injectable in tests (the
mail transport pattern).

**Triggers**

- Interval pass every **5 minutes**, jittered per repo.
- Manual **Sync now** RPC.
- `full` mode only: ICM-watcher-debounced commit trigger after **~2
  minutes of quiet** (edits commit promptly, not per keystroke).

**Pass order per repo** (repos serialized; one pass at a time per repo):

1. **Refresh state** — branch, upstream, dirty, ahead/behind, in-progress
   merge/rebase. Conflicted or mid-merge/rebase state (whoever left it) →
   **held** + `merge_in_progress` notice; stop.
2. **Auto-commit** (`full` only): if dirty, `git add -A` +
   `git commit -m "valea sync: <ISO8601>"`. `.gitignore` is respected, so
   the gitignored `secrets/` convention holds automatically.
3. **Fetch.**
4. **Behind only** → `git merge --ff-only @{u}`. In `pull` mode with a
   dirty tree, git itself refuses a checkout that would clobber local
   edits → `blocked_local` notice; nothing is lost.
5. **Ahead only, `full` mode** → push. Rejection (remote moved since
   fetch) → re-fetch → falls into 6.
6. **Diverged** (both moved) → **held** + `diverged` notice. Valea never
   merges, rebases, or force-pushes.

**Held means held.** A held repo gets local status reads only — no fetch,
no commit, no network — so the engine can never race a resolving agent's
index, refs, or network operations. The hold lifts automatically when a
pass re-derives clean state (no resolution state machine; derived truth
only).

**Status** — in-memory per repo, pushed over the workspace events channel
(mail-statuses pattern) and summarized in cockpit `today.json`:

```
{mode, branch, dirty, ahead, behind,
 state: ok | syncing | blocked_local | held | error,
 last_sync_at, last_error}
```

Network/auth failures back off exponentially (capped) and set
`state: error` — doctor material, never an agent notice.

## Conflict notices and the agent handoff

**Notice classes** (cockpit notices; windowed + capped like schedule
notices; dedup key `(mount_key, local_sha, remote_sha)`):

- `diverged`, `blocked_local`, `merge_in_progress` — agent-actionable;
  each carries the **Resolve with agent** button.
- Fetch/push/auth failures are *not* notices (status + doctor only).

**RPC `start_git_conflict_session(mount_key)`** — the button:

1. **Re-verify live git state.** Never trust a stale notice; if the
   conflict is gone, return that and the UI clears the notice.
2. **Compose the briefing** deterministically: repo/branch/mode;
   ahead/behind counts; capped lists of local-only and remote-only commit
   subjects; conflicted/dirty file list (capped); then the resolution
   contract — resolve preserving both sides' intent; merge or rebase at
   your judgment; never force-push; never discard changes silently; push
   when clean; summarize what you did — then the per-ICM `instructions:`
   prose, if any.
3. **Create a normal visible session**: `kind: "chat"`, cwd = this ICM as
   primary mount, title "Git sync conflict — <name>", via the existing
   `create_agent_session` + `initial_prompt` path. The agent starts
   immediately; risky commands remain ask-gated by PermissionPolicy (the
   user is present — they clicked).
4. **Record `session_id` on the notice.** While that session lives, the
   button renders **Open session** instead — no accidental second
   resolver. (Same shape as the Spec H "session_id on waiting notices"
   backlog item.)

The repo stays held throughout; the first pass after the agent finishes
re-derives clean state, and hold + notice clear on their own.

## Doctor

Mounts-doctor pattern additions:

- Workspace-level: git binary present (`System.find_executable`).
- Per git-ICM: repo-root-at-mount-root check, upstream configured, last
  fetch/push outcome, detached-HEAD note, and an auth-specific hint when
  fetch fails authentication — including the packaged-app caveat that the
  Tauri-launched backend may lack `SSH_AUTH_SOCK`/agent env.

## UI

- **Cockpit**: notice cards with the Resolve/Open-session button; git
  summary line in `today.json`.
- **Sidebar**: sync-state badge on the ICM project row
  (synced / syncing / attention).
- **ICM settings**: sync-mode control + **Sync now**.

No new routes.

## Testing

- Fixture harness: tmp bare "remote" + two clones fabricating every
  scenario — ahead, behind, diverged, dirty-blocked, mid-merge.
- Engine pass-order tests against the `Git.Cli` seam; real-git integration
  tests over the fixtures (skip when `git` absent).
- RPC test asserting briefing content (counts, caps, instructions
  inclusion) and session creation with `initial_prompt`.
- FE: status store, notice card, badge states.
- Live acceptance doc: real remote on the `workspace` ICM — full-mode
  round trip, manufactured divergence, one-click resolution session,
  packaged-app fetch (ssh-agent env check).

## Accepted residual risks / limitations

- **`git add -A` commits everything untracked** in `full` mode — a stray
  large or sensitive file that is not gitignored gets committed (not
  pushed silently into public: push only goes to the ICM's own remote).
  Mitigation is the existing gitignore discipline; called out in docs.
- **Auto-commit message carries no intent** (`valea sync: <ts>`); history
  in `full` ICMs is a sync journal, not a narrative. That is the accepted
  cost of the mode; curated repos use `pull`.
- **The engine follows the checked-out branch.** Work left on a
  non-upstream branch simply doesn't sync (observe-only doctor note).
- **Concurrent same-repo actors outside Valea** (user terminal, systemd
  timers) can race a pass; git's own locking makes this safe, and any
  surprising end state is re-derived next pass. Sub-5-minute staleness of
  the status display is accepted.
- **Two workspaces mounting the same repo** would both sync it; git
  locking keeps it safe, duplicate notices are possible. Rides the
  single-workspace-per-repo reality; not defended in v1.

## Out of scope

- SMTP-style outbound review flows for pushes; push is mode-gated instead.
- Merging/rebasing/force-push by Valea, ever.
- Multi-remote, submodules, worktree links, bare repos.
- Git for the managed workspace dir itself (this is ICM mounts only).
- Conflict resolution UI in Valea (diff viewer etc.) — the agent session
  is the resolution surface.
