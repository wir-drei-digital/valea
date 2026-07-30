# ICM Git Sync — State, Auto-Sync, Conflict → Agent Handoff

**Date:** 2026-07-30
**Status:** **Shipped** 2026-07-30. The body below is the approved design as
written and is kept unedited. Where the implementation deliberately
diverged — all of it review-driven — the differences are recorded in
[Implementation amendments (2026-07-30)](#implementation-amendments-2026-07-30)
at the end; **that section, not this body, describes what runs.** Live
acceptance: `docs/superpowers/acceptance/2026-07-30-icm-git-sync.md`.

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

## Implementation amendments (2026-07-30)

Written after the fact, against the shipped code (`Valea.Git.Engine`,
`Valea.Git.Repo`, `Valea.Mounts.Doctor`, `Valea.Api.Git`, `stores/git.svelte.ts`).
Everything above stands as the approved design; the five items here are
where implementation review moved it, and each one is a behavior change a
reader of the body would otherwise get wrong. Nothing here weakens the two
invariants the design exists for: **Valea never merges (non-ff), rebases,
force-pushes or discards**, and **held means held**.

### 1. Pass order

The body's "Pass order per repo" listed refresh → auto-commit → fetch →
ff → push → diverged. The shipped order derives *everything holdable from
one local read first*, and only a repo that reads `ok` is allowed to touch
the network (`Engine.classify/8` → `local_class/4` → `converge/8`):

1. **One local state read**, then classify, in this order:
   `merge_in_progress` (an in-progress merge/rebase **or** a conflicted
   index) → `detached` → `no_upstream` → `diverged` → `blocked_local` →
   `ok`.
   - **`merge_in_progress` is checked first, before the branch check.** A
     conflicted *rebase* has a detached HEAD; classifying on `branch` first
     would label every rebase-in-progress `detached` — observe-only, not
     conflict-class — and the resolution session could never be handed off
     for exactly the repo that needs it most.
   - **`diverged` is derived from the last-known remote refs, BEFORE any
     fetch.** This is what makes "held means held" literal: a held repo
     performs no network call at all, so its hold cannot be re-derived from
     a fresh fetch. The cost is that a divergence created purely on the
     remote is noticed one pass late; the benefit is that a status row
     cannot keep changing under a user (or an agent) mid-resolution.
2. **Auto-commit** (`full` only, dirty tree) — reached only on `ok`.
3. **Fetch** — skipped while a backoff window is open (the row then repeats
   the previous error over freshly-read local facts).
4. **Re-read, then**: both moved → hold `diverged`; behind only →
   `merge --ff-only`; ahead only in `full` → push; otherwise converged.

The consequence worth stating plainly: **in `full` mode a dirty repo that
is also behind still commits.** Commit → fetch → the repo is now genuinely
diverged → held, with the user's work preserved *as a commit*. The
alternative (hold before committing) would suspend full mode's entire
contract behind uncommitted edits and leave the work sitting in the working
tree with no record.

### 2. `blocked_local` is pull-mode only, learned, and fingerprint-held

The body describes `blocked_local` as what happens when "git itself refuses
a checkout that would clobber local edits". Shipped, that is tightened
three ways:

- **Entered ONLY from a real refusal.** The single site is a
  `git merge --ff-only` that git actually rejected (`Engine.fast_forward/5`).
  It is never inferred from "behind and dirty": most dirt blocks nothing
  (an untracked editor file, an edit to a file the incoming commit never
  touches) and git fast-forwards straight past it. A repo held on that
  guess would be held **forever** — held repos never fetch, so `behind`
  could never fall and the remote's work would never arrive.
- **Held for exactly as long as the tree git judged.** A refused
  fast-forward leaves the working tree byte-identical, so the refusal
  records a fingerprint of it — the sorted set of changed paths (capped at
  200) plus both shas, all local reads. While the fingerprint matches, the
  repo stays held with no network: git already answered this question. The
  moment it changes — the blocking file reverted, another added or removed,
  a commit made — the verdict has expired and the repo converges, where
  **git, not Valea, decides again**: a tree that still clobbers is refused
  again and re-learns the hold (one fetch, one refused ff, both data-safe),
  and resolved dirt fast-forwards. This is what makes "the user cleaned up
  the file that was in the way" a real exit rather than a claim.
- **`pull` mode only.** In `full` mode the answer to a dirty tree is to
  commit it (see amendment 1), so a refusal there is *not* "the user has
  uncommitted work" — it is something `git add -A` could not take (an
  ignored file the merge would clobber, a permissions problem) and is
  reported as `error` in git's own words, rather than borrowing a state
  whose remedy ("commit or revert your edits") does not apply.

**This is a justified exception to the body's "no resolution state machine;
derived truth only."** `blocked_local` is the one state git exposes no
marker for — nothing in `.git` records "a fast-forward was refused" — so
holding it requires the pass to read its own previous row. The exception is
deliberately minimal: one boolean verdict plus one fingerprint, carried on
the in-memory status row only (never written to disk), self-expiring on any
tree change, and re-decidable only by git. No other state reads the past.

**Reconciling the body's wording.** Step 4's "→ `blocked_local` notice;
nothing is lost" is accurate about the *data* — the refused fast-forward
leaves the working tree untouched, which is precisely why the fingerprint
taken at that moment describes the tree git ruled on — but it should not be
read as "the notice is a momentary observation". It is a **hold**: while it
stands the repo does no fetch, no commit and no push, and it lifts on a
tree change or a successful convergence, not on a timer.

### 3. Conflict sessions: derived state + an engine-side claim, not a stored notice

The body specifies notices with a dedup key `(mount_key, local_sha,
remote_sha)` and "record `session_id` on the notice". Shipped, there are no
notice records at all — the surfaces render **derived state**:

- Every status row carries `local_sha` / `remote_sha` (`nil` wherever git
  could not answer) and `conflict_session_id`. The identity triple is
  therefore *on the row*, available to any consumer that wants to tell "the
  same conflict, still there" from "a new one", with nothing stored.
- The button's "no accidental second resolver" property comes from an
  **atomic claim protocol in the Engine**, not from reading a notice:
  `claim_conflict_session/2` (a call) reserves the repo's single resolution
  slot **before** the caller resolves a scope and handshakes an agent
  subprocess, and `record_conflict_session/2` (a cast) confirms it
  afterwards. Two clicks — a double-click, two tabs, two windows —
  serialize on the Engine loop: exactly one starts an agent, the other is
  routed to the existing session. Claim-after-start would let both callers
  read an empty slot and point two agents with write scope at the same
  conflicted working tree.
- A slot is held against something observable: a pending claim against its
  **caller** (monitored — a caller that dies mid-start releases it), a
  confirmed one against the **session** (`SessionServer.running?/1`). An id
  that is neither is a dead reference the next caller takes over, so a
  killed session can never make a repo permanently unresolvable.
- The RPC is `start_git_conflict_session` and still re-verifies live git
  state first; a conflict that is gone returns that, and the UI clears.

### 4. Doctor

- The per-mount check's **label is `"<mount key>: git sync"`** (the sibling
  mount checks' convention); the stable id remains `git_sync:<mount_key>`.
- **Disabled and degraded mounts short-circuit to `unknown`** before any
  probe — `not checked — this mount is disabled.` /
  `not checked — this mount is degraded, so nothing is syncing it.` The
  engine skips those mounts entirely, so a real verdict for one would be a
  finding the user cannot act on (and would flip `ok: false` for an ICM
  that is off by intent). Same posture as `watcher_live`.
- The spec's "last fetch/push outcome" is read from the **live engine row**:
  a `state: "error"` row makes the check `failed` with git's own words. A
  held or converged row does not — a hold is a situation with its own
  surface, not a doctor failure.
- When the error text looks auth-shaped (`/auth|permission|denied|publickey/i`)
  the remedy names the packaged-app caveat: *the packaged app may lack your
  ssh-agent environment — try launching from a terminal, or check the
  remote's credentials.*

### 5. Statuses

- The `state` enum keeps **`syncing`**, but the v1 engine **never emits
  it**: a pass runs to completion in one task and publishes one row.
  Consequently the sidebar badge is **attention-only** (the three
  agent-actionable holds), not the body's synced/syncing/attention triple —
  "quiet unless something needs you" is the shipped rule, and a per-repo
  status line lives in the ICM's *Git sync…* panel for anyone who wants
  detail.
- Shipped `state` values: `ok`, `syncing` (unused), `diverged`,
  `blocked_local`, `merge_in_progress`, `error`, `off`, `detached`,
  `no_upstream`, `unsupported`.
- `error` remains **doctor/status material and never an agent notice**, as
  specced — fetch/push/auth failures do not raise a Today row.
