# Acceptance run — ICM project workspaces

Run: 2026-07-16, dev build (`just dev`, branch `feat/workspace-profiles` @ c5f99dc),
driven in the browser preview against fresh `VALEA_APP_DIR` scratch dirs. Nothing
was checked without being observed; deviations and automation caveats are noted
inline. Two pointer-event quirks of the automated browser pane (dropdown menus
closing on window blur; Svelte `bind:value` not seeing synthetic value sets)
required keyboard/programmatic fallbacks in places — both were verified to be
automation artifacts, not app defects (the same controls worked by hand in the
Task 10.4 / 10.2–10.3 implementer runs and via real key events here).

## Scenario 1 — Fresh start ✅ PASS

Onboarding "Start fresh" → Name **Mara Lindt Coaching**, accepted the suggested
visible location `~/Documents/Valea/Mara Lindt Coaching` (folder field
live-followed the name; secondary "Workspace name" field live-defaulted).

- Hidden workspace created: `<app-dir>/workspaces/mara-lindt-coaching-1fd39067/`
  (v5, `icms:` maps the ICM by reference; no workspace path ever shown in UI).
- ICM created + mounted at the chosen visible location with the portable
  starter (AGENTS/CLAUDE/CONTEXT, Decisions/, Templates/, Workflows/, icm.yaml).
- Sidebar shows the ICM as a project group; flow landed on `/chat?icm=…`.
- First session started; transcript line 1 (`session/v1`):
  `icm_mount: mara-lindt-coaching`, `icm_root: /Users/daniel/Documents/Valea/Mara
  Lindt Coaching`, workspace id/name — **cwd is the ICM**, verified on disk.

## Scenario 2 — Existing ICM ✅ PASS

Second fresh app dir → onboarding "Use an existing ICM folder" → typed a path to
an existing healthy ICM → **preview rendered before any mount** (Location, Name
"Coaching", calm copy), editable workspace name → "Use this folder".

- Hidden workspace `coaching-7182745f` created — **no workspace-folder prompt
  anywhere**.
- ICM mounted **in place** (config `path` = the original folder; nothing copied
  or moved). Landed on `/knowledge?icm=coaching` with the tree; the sidebar
  group offers New session.

## Scenario 3 — Two ICMs ✅ PASS

Mounted **Legal** (pre-existing external folder) alongside Coaching via the
Knowledge "Mount a folder from elsewhere…" dialog — `inspect_icm` preview
(Location/Name/Description) gated the Mount button; both ICMs then appear as
sidebar projects.

- Session under **Legal**: transcript `icm_mount: legal`, `icm_root` = Legal's
  folder; managed `context.md` says cwd is Legal's root, **Related ICMs: (none)**
  — Coaching not loaded.
- Session under **Coaching** (before any declaration): Related ICMs **(none)** —
  Legal not loaded. Isolation both directions.
- (The sidebar "Mount an ICM → Create a new ICM…" dropdown itself was verified
  live in the Task 10.4 run; here the shared dialog path was exercised.)

## Scenario 4 — Related ICM ✅ PASS

Declared Legal **by id** in Coaching's `CONTEXT.md` frontmatter
(`format: 1`, `related_icms: [- id: 937431df-…, name: "Legal"]`).

- New Coaching session's `context.md` lists exactly one related ICM: Legal's
  resolved root + entrypoint. No other mounted ICM joined.
- Negative case observed first: a malformed frontmatter shape (flat id list, no
  `format: 1`) soft-fell-through to "(none)" with no error — exactly the
  documented optional-declaration contract.
- Footnote: the entrypoint (`…/legal/CONTEXT.md`) was listed although that file
  does not exist in this Legal fixture — resolution is boundary-checked but not
  existence-checked; the agent would simply fail to read it when routing calls
  for it. Consider an `icm_doctor` related-ICM note (it has a `related_icms`
  check; entry-point existence could join it).

## Scenario 5 — Workspace separation ⚠️ PASS with findings

Created **Consulting** via the app's own `create_workspace` RPC, mounted the
**same** Legal folder into it.

- Switch stops the old runtime; sidebar/account data swap (Consulting shows only
  Legal; chat history empty — Coaching-workspace sessions not visible).
- Legal is the same physical folder in both workspaces (same `path`, same
  manifest id) — histories stay separate per workspace.
- Switched back via the WorkspaceSwitcher menu → Mara Lindt Coaching returns
  with its sessions (after reload — see Finding 2).
- Mail/credentials: **N/A in this environment** (no real IMAP credentials).
  Keychain keying by workspace id is covered by the automated suite; not
  re-proven live.

**Finding 1 (product gap):** there is **no in-app UI to create a second
workspace** — the switcher lists/switches only; workspace creation exists solely
in onboarding (and the RPC). A returning user cannot add "Consulting" without
wiping state or calling the RPC by hand. Not in any phase's scope; needs a
product decision (e.g. "New workspace…" item in the switcher).

**Finding 2 (bug, fixed in wave `<see ledger>`):** immediately after a live
workspace switch the sidebar ICM groups and session lists rendered **empty until
a manual reload** — the store refreshes raced the generation bump. Reproduced
twice. (Cold load populates correctly; this is the switch path only.)

## Scenario 6 — Workflow ◐ PARTIAL

- "Distill recent decisions" (Today) was invoked live; it correctly **no-ops in
  a fresh workspace**: `Valea.Workflows.Distill.digest/1` compiles decided queue
  items (`queue/approved|rejected`, 30-day window) and there were none. Expected
  behavior, verified against source; not a failure.
- The structural invariants this scenario exists for are covered by the
  automated suite and two opus reviews (Phase 5 policy + root sets; Phase 7
  exact input/staging grants, `run.json` sidecar, locator-keyed approval,
  audit provenance): workflow session cwd = owning ICM; grants = exact input +
  staging only; approval/audit stay in the launching workspace.
- **Deferred live case:** an end-to-end live workflow run (against a decided
  queue item or a configured mail source). Recipe: approve/reject one queue item
  (or configure mail + Run triage on a message), then Distill; verify the run
  session's transcript `icm_root`, the `run.json` sidecar, and the queue item's
  ICM locator. The ask/deny permission halves of a live agent session WERE
  proven end-to-end on 2026-07-16 (see `docs/notes/acp-launch-contract.md`
  addendum).

## Testing-strategy sweep

40 spec cases mapped (see the SDD ledger's sweep output): **32 covered, 4
partial, 4 not covered**. Gaps recorded for follow-up (none release-blocking;
several are frontend render-harness class, which this repo deliberately lacks):

1. Same physical ICM mounted into two workspaces — no cross-workspace fixture
   (partially compensated by Scenario 5 above, live).
2. Unrelated mounted-but-undeclared ICM excluded from session launch — pattern
   exists for search/backlinks, not for `session_scope` read_roots directly
   (compensated by Scenario 3 above, live, and PermissionPolicy tests).
3. Related ICM's instruction content proven absent from harness input — only the
   pointer is asserted.
4. Required-workflow preflight for a missing related ICM — deferred by design
   (SessionScope moduledoc).
5. Live-session dot rendering; 6. `+` button mountKey wiring; 7. tree-exclusivity
   — all frontend render-harness class.

## Verdict

Scenarios 1–4 pass outright; 5 passes with one product gap (no second-workspace
UI) and one switch-refresh bug (fixed in a follow-up wave); 6 is partially
observed live with its structural core automated-verified and a precise recipe
for the remaining live case. `just test` green (backend 962/0/0, frontend 680,
check 0) at the time of the run.
