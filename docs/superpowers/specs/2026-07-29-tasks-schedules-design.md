# Tasks & Schedules — Per-ICM Ledgers, Internal Scheduler

**Date:** 2026-07-29
**Status:** Approved (design); Codex adversarial rounds 1–3 folded
(2026-07-29: every code-grounded claim verified against source; round 1
~20 findings, round 2 verified the folds + 14 findings on the new
machinery, round 3 verified those folds + 3 majors and 2 precision
blockers — one settled by official-doc verification of harness permission
precedence — each folded as a design change or explicitly accepted below).
Pending implementation plan.

## Goal

Give Valea a native task concept and a native scheduling concept without
breaking the file-first invariant or creating tool lock-in. Both are plain
JSON files in the ICM root — agent-writable, hand-editable, portable — that
Valea parses, renders, and (for schedules) executes. Valea owns only the
meta layer: run history, archival, audit, and the UI.

This fills two holes at once:

1. **Tasks** — a self-employed user must see, add, assign, and complete the
   day's work in one place; agents must be able to contribute to and pull
   from the same list. The old Tasks nav stub (deleted 2026-07-26) returns
   as a real feature.
2. **Schedules** — today, recurring automation means hand-wired systemd/cron
   units: invisible to the UI, opaque to non-technical users, absent from
   the audit trail. Valea offers an in-app, transparent, pausable registry
   that agents can write to, replacing "confusing OS scheduler" for the
   common cases. (Roadmap item "headless/scheduled sessions"; this spec
   claims the scheduled-session half. A deterministic-step contract beyond
   `command` payloads stays future scope.)

## Decisions settled with Daniel (2026-07-29)

- **Task semantics: shared work ledger.** One list per ICM; each task has an
  assignee (`user` or `agent`). Agent-assigned tasks are *pulled* by sessions
  (the user says "work the task list", or a scheduled prompt says so) —
  Valea never auto-executes a task.
- **Day scoping: backlog + due/focus dates.** One flat ledger; tasks
  optionally carry `due` and/or a `today` flag. "Today" is a filter, not a
  per-day file.
- **`today.json`: tasks absorb `open_loops`.** The task ledger becomes the
  single "needs attention" surface. `today.json` keeps `notes` and
  `prepared` only; the cockpit stops parsing `open_loops`; the briefing
  tells agents to use tasks instead.
- **Execution model: Valea-internal scheduler.** A per-workspace GenServer
  fires schedules while Valea runs. No OS-timer management (launchd/systemd
  would bypass PermissionPolicy and the audit log, and is platform-divergent).
  Limitation stated honestly in the UI: nothing fires while Valea is closed.
- **Activation: active immediately, kill switch.** No separate approval
  queue. The consent moment for agent-registered schedules is the
  `schedules.json` write itself, which PermissionPolicy **always asks** on
  (a real policy rule — grants never auto-allow it; see Consent). After the
  approved write the schedule is live. Cockpit notices announce new/changed
  schedules; every schedule is pausable; a global Pause-all switch exists.
- **Agent teaching: one pattern for all — the mail briefing pattern.**
  A Valea-materialized briefing file (like `Valea.Mail.AgentsFile`), plus
  self-describing `readme` fields in both JSON files, plus one pointer line
  in every session's Valea-authored `context.md`. That last surface is what
  reaches EXISTING ICMs: their `AGENTS.md`/`CLAUDE.md` is user-owned prose
  Valea never rewrites, so the template pointer only seeds new ICMs —
  `context.md` is regenerated per session and covers every ICM, old or new.
  No skill, no MCP tool, no RPC for agents: **the file is the API**.
- **Scheduled sessions stay out of the session list by default** (Daniel:
  clutter). They get their own `kind` and are reached through each
  schedule's run history; a debug toggle can reveal them in the lists.
- **No Oban.** Truth is files in user-owned ICM roots; the scheduler
  re-derives due work from the files and a small persisted anchor per
  schedule. Oban would add a second DB-resident truth tied to the
  per-workspace Repo lifecycle, plus retry machinery this feature doesn't
  need (the next slot is the retry).
- **Accepted residual risks (post-Codex round 1, Daniel 2026-07-29):**
  1. *Command content drift* — an approved command schedule's target script
     can change later via ordinarily-granted writes; the next unattended
     fire runs the new content. Accepted as parity with the user's existing
     systemd timers; mitigations: always-ask registration, per-fire audit
     with the full command line, pause/kill switch. No hash-pinning.
  2. *External writers* — a hand edit or sync tool can create an active
     schedule without a Valea-observed consent event. The user owns those
     channels; accepted.
  3. *Same ICM mounted in two workspaces* — each workspace keeps its own
     scheduler anchors, so one cron slot can fire once per workspace
     (around a switch, or with two app instances). Accepted and documented;
     no cross-workspace lease.
  4. *Task deletion by agent rewrite* — undetected in v1 (no destructive-
     delta detection). Briefing instructs "set status, never delete";
     archive + transcripts are the safety nets.
  5. *Final-window lost updates are unrecoverable for open entries* — a
     whole-file write landing between Valea's last hash check and its
     rename is silently overwritten; open (non-archived) tasks in that
     window have no archive or audit copy to recover from. Accepted: the
     window is microseconds on a human-scale file; POSIX rename offers no
     true CAS and a lock file in user territory is not acceptable.
  6. *Opaque shell writes reach the ask untagged* — a `Bash`-kind item has
     no extractable path candidates, so a shell redirection onto
     `schedules.json` falls to the generic `:ask` (verified: empty
     candidates → `:ask`, and the managed-settings posture keeps `Bash` in
     the harness "ask" list) rather than the labeled schedule-registration
     ask. Never a silent allow — but the dialog can't say "this registers
     a schedule". Accepted; the briefing directs agents to edit the
     ledgers with file tools, and an unattended session parked on the ask
     still fails closed.

## Data model

### `tasks.json` (ICM root)

```json
{
  "readme": "Task ledger for this ICM. Managed by Valea and agents. Contract: .valea/briefing.md",
  "tasks": [
    {
      "id": "t-8f3a2c",
      "title": "Send Kita offer follow-up",
      "notes": "optional freeform",
      "status": "open",
      "assignee": "user",
      "due": "2026-07-30",
      "today": true,
      "priority": "high",
      "source": "mail:w3d/INBOX/<msg_id>",
      "created_by": "agent",
      "created_at": "2026-07-29T08:00:00Z",
      "updated_at": "2026-07-29T08:00:00Z",
      "done_at": null
    }
  ]
}
```

- **Statuses:** `open → in_progress → done`, plus `dropped`. Nothing more.
- **Assignee:** `"user" | "agent"`.
- **Priority:** `"high" | "medium" | "low"`, optional.
- **`source`:** optional freeform provenance locator (mail message, file
  path, URL). Rendered as text/chip; only locators Valea recognizes become
  links (mail message locators, `(mount_key, rel_path)` file locators).
- **IDs:** opaque short strings, generated by whoever creates the task
  (convention: `t-` + 6 hex chars). Tasks are inert (nothing executes), so
  duplicates degrade softly: first occurrence wins for UI addressing and a
  calm per-ICM note flags the duplicate. UI addressing is
  `(mount_key, id)` like all ICM content.
- **Timestamps:** ISO 8601 UTC. Optional-but-recommended; leniency applies.

### `schedules.json` (ICM root)

```json
{
  "readme": "Schedules for this ICM. Fire only while Valea is running. Contract: .valea/briefing.md",
  "schedules": [
    {
      "id": "s-morning-brief",
      "title": "Morning inbox brief",
      "cron": "30 7 * * 1-5",
      "timezone": "Europe/Zurich",
      "payload": {
        "kind": "prompt",
        "prompt": "Work the inbox-triage workflow and update tasks.json.",
        "context_doc": "communications/workflows/inbox-triage.md"
      },
      "paused": false,
      "catchup": false,
      "created_by": "agent",
      "created_at": "2026-07-29T08:00:00Z"
    }
  ]
}
```

- **Payload kinds:**
  - `prompt` — starts a normal agent session via the Spec D
    session-with-context primitive: cwd = this ICM, optional `context_doc`
    (ICM-relative path), `kind: "scheduled"`. The session is ask-gated per
    action like any other; nothing about being scheduled weakens posture.
  - `command` — `{"kind": "command", "command": "python3", "args":
    ["scripts/sync.py"]}`. Exec-style spawn: `command` + `args` array,
    **never a shell string**, no shell interpolation. The executable
    resolves like a terminal would (absolute path, ICM-root-relative, or
    PATH lookup); env is the platform allowlist (Windows-support
    precedent); cwd = ICM root. **There is no sandbox**: a command runs
    with the user's full authority — that is exactly why registration is
    always-ask and drift is an explicitly accepted risk. Generous fixed
    timeout (10 min), output captured and capped (256 KiB) into the run
    record.
- **Cadence:** standard 5-field cron plus `@hourly/@daily/@weekly/@monthly`
  aliases. Timezone defaults to the host zone (same source as calendar's
  `Engine.host_zone/0`); per-schedule `timezone` override. Parser is
  hand-rolled and deterministic (~100 lines, vectors-tested) — no new dep
  for a 5-field grammar. **Semantics are pinned:** Vixie DOM/DOW rule
  (when both day-of-month and day-of-week are restricted, a match in
  *either* fires; otherwise the restricted one governs). Slot
  materialization is defined in UTC instants — see Scheduler runtime.
- **`paused`** is a file field — a hand edit or agent edit can pause too;
  the file alone fully describes the schedule's *desired* state (runtime
  anchors and the workspace kill switch live Valea-side). A pause takes
  effect within one tick (≤ 30 s) for any fire whose pre-launch snapshot
  follows the write; a pause landing inside the snapshot-to-spawn window
  (milliseconds) may miss that one fire — the guarantee is snapshot-based,
  not instantaneous revocation. Slots that elapse while paused are
  consumed silently (the anchor advances, nothing fires, nothing is
  recorded), so unpausing never back-fires missed slots.
- **`catchup`** (default `false`): on workspace open, at most **one**
  coalesced fire if slots passed while Valea was closed (systemd
  `Persistent=true` semantics). With `false`, missed slots are consumed
  silently on open.
- **Declaration only.** No run state in the file. Anchors, outcomes, and
  history live Valea-side in the workspace SQLite (see Scheduler runtime
  for the exact state model). This is the "files for facts, Valea for
  meta" split — runtime state never touches the files at all (Valea's
  ledger writes and their separate race window are covered under Write
  discipline).

### Leniency contract — lenient display, strict execution

Two regimes, deliberately split (Codex round 1):

**Display fields are lenient**, `today.json`-style: missing file → empty
ledger/registry; malformed JSON → file treated as absent for execution
(**nothing fires from an unparseable `schedules.json`** — fail-safe) with a
calm per-ICM note ("unreadable — fix by hand or ask the agent") and one
audit notice per content-hash; wrong-typed display fields (title, notes,
priority, source, created_*) degrade to nil/defaults; unknown statuses
render as text and sort last. **Unknown fields are preserved on write** —
when Valea patches an entry it round-trips keys it doesn't understand.

**Execution-control fields are strict and fail closed, per entry.** For a
schedule these are: `id`, `cron`, `timezone` (when present), `payload`
(shape and kind), `paused` (must be a JSON boolean when present), `catchup`
(same). Any invalid, missing-required, or wrong-typed value makes that
entry **not executable**: it never fires, and the UI shows it with a
per-entry reason ("invalid cron", "unknown timezone", "`paused` is not a
boolean" — a malformed *pause attempt* must never yield a running
schedule). Entries without `id` are not executable and not addressable.
`context_doc` is validated strictly for containment: it must be a relative
path that stays inside the ICM root (lexical check at validation,
`resolve_real` containment at launch — a symlink escape fails the launch);
a `context_doc` that doesn't exist at launch time produces a `failed` run
record, not a weaker session.
**Duplicate schedule ids exclude every carrier from execution** ("duplicate
id" disposition) — array order never decides what runs, so a reorder can
never silently swap payloads. Each parsed entry gets a stable disposition
(`executable | paused | not_executable(reason)`) exposed through the RPCs
so every row is attributable and repairable. While an entry is
non-executable its elapsed slots are consumed silently (Firing rule
step 6), so repairing it never back-fires the slots it missed.

Tasks have no execution semantics and stay on the lenient regime; the UI
adds **repair affordances** for the degenerate cases (assign an id to an
id-less entry, normalize an unknown status via the editor) so nothing is
visible-but-unfixable.

### Write discipline

- All Valea-side mutations of a given ICM's ledger files serialize through
  **one per-ICM writer** (a process, not a convention), so UI clicks,
  RPCs, and archive sweeps never interleave with each other.
- Each Valea mutation is an entry-level read-patch-write with **optimistic
  concurrency**: read the file and record its content hash → apply the
  patch to the affected entry → re-check the hash → atomic temp+rename.
  On mismatch, re-read and re-apply the patch against the fresh content
  (the patch targets an entry by id), bounded retries (3); if the target
  entry vanished or contention persists, surface a conflict to the UI
  instead of writing. This shrinks the lost-update window from "an entire
  UI interaction" to microseconds. The residual race (a writer landing
  between the final hash check and the rename) is **accepted residual
  risk #5** — for open entries it is plain unrecoverable data loss, and
  the spec says so rather than claiming the archive bounds it (the archive
  only ever holds completed entries).
- Agents use their ordinary file tools; no transactional ceremony is asked
  of them. The briefing instructs read-fresh-then-write-promptly. Torn or
  interim states are tolerated by the leniency contract and self-heal on
  the next good write. Agent-vs-agent write discipline is out of Valea's
  hands (accepted).
- Changes ride the existing `icm_changed` watcher **for UI refresh only** —
  the watcher is best-effort by contract (disabled state, re-subscription
  loss window, 200 ms debounce) and is never on the execution path.

### Archival

Completed (`done`/`dropped`) tasks are archived by Valea — appended to
`.valea/task-archive.jsonl` (one JSON object per line, as-archived, with an
`archived_at` stamp) and removed from `tasks.json`:

- UI "Clear done" button, per ICM or all.
- Auto-archive: tasks `done`/`dropped` for > 14 days, swept by the
  scheduler process on workspace activation and once per day thereafter.
- **Crash-safe ordering:** append to the archive first, prune the ledger
  second, both through the per-ICM writer. Each archive line carries a
  generated event id (UUID, provenance only) plus the entry snapshot and a
  **snapshot content hash — the hash is the identity**: task
  `id`/`updated_at` are optional-and-mutable and never identify anything,
  and a crash between append and prune means the next sweep may append
  the same snapshot again under a fresh event id — readers dedupe by
  snapshot hash, so re-appends are harmless. (Corner, stated: genuinely
  distinct archivals of byte-identical content collapse on read — same
  fact, acceptable.) **Prune is snapshot-conditional:** an entry is
  removed from the ledger only if its current content still hashes to the
  archived snapshot; an entry edited or reopened between append and prune
  stays in the ledger (the archive line remains as history of the
  completed state it captured). A partial trailing line (crash mid-append)
  is tolerated and ignored by readers; the next append repairs by starting
  on a fresh line.
- Agents are told: set status, never delete — Valea owns archival. The
  archive doubles as greppable "what got done when" history, readable with
  any text tool (it lives in the user-owned ICM tree).

### `.valea/` — Valea's namespace inside the ICM

- `.valea/briefing.md` — materialized contract doc (below). Header marks it
  regenerated-by-Valea; edits are overwritten.
- `.valea/task-archive.jsonl` — append-only archive.
- **Agent sessions cannot write anywhere under `.valea/`** — a
  PermissionPolicy deny (settings-mirror precedent), because the briefing
  is an instruction surface and the archive is Valea's ledger. Reads stay
  ordinary. Users can of course edit by hand; the briefing is regenerated
  write-if-different on activation.
- Nothing else moves in without a spec. The dir is plain files, owned by
  the user like everything in the ICM, committable or ignorable at their
  discretion.

## Scheduler runtime

`Valea.Schedules.Scheduler`, one GenServer per workspace under the
Workspace Runtime (same lifecycle as mail/calendar engines; dies and
restarts with workspace switch).

### Persisted state (workspace SQLite)

Keyed by `(icm_id, schedule_id)` where `icm_id` is the ICM's
`manifest.id` — the persistent identity that survives mount rename/re-add.
The mount key is display metadata on records, never the key. Per schedule:

- `fingerprint` — SHA-256 over the entry's **execution-relevant fields
  only**, canonicalized (key-sorted): `cron`, `timezone`, `payload`,
  `catchup`. Display edits (title, notes, unknown fields) and `paused`
  toggles deliberately do NOT change it — a title fix seconds before a due
  slot must not suppress the fire, and pause/unpause must not reset the
  anchor.
- `first_seen_at` — UTC instant this fingerprint was first observed.
- `last_attempted_slot` — UTC instant of the most recent **consumed** slot
  (fired, skipped, fast-forwarded, or consumed-while-paused). This is the
  anchor; it is **monotonic — it never moves backward** — and there is no
  global tick watermark: nothing that matters lives only in process state.
- `deleted_at` — tombstone. Set when a *parseable* file no longer contains
  the schedule's id (an unreadable file is never treated as deletion —
  fail-safe). Any reappearance of the id — even byte-identical — resets
  `first_seen_at`/`last_attempted_slot` to now and clears the tombstone,
  so delete-recreate never inherits old anchors, exact recreation
  included.
- Run records: `(fingerprint, slot, fired_at, trigger
  scheduled|catchup|manual, kind, outcome, duration, session_id |
  output_ref, coalesced_count)`. Records survive schedule deletion.

### Firing rule (evaluated per tick, every 30 s)

1. **Re-read `schedules.json` synchronously** for each enabled ICM —
   strict-validate per entry (dispositions above). No cache on the
   execution path; watcher events only refresh the UI.
2. **Fingerprint + tombstone reconciliation:** an entry whose fingerprint
   differs from the stored one, is new, or reappears after a tombstone
   resets its state — store the new fingerprint, `first_seen_at = now`,
   `last_attempted_slot = now`, tombstone cleared. A previously-seen id
   absent from a *parseable* file sets the tombstone (an unreadable file
   never does). A definition change or delete-recreate — byte-identical
   recreation included — therefore never inherits old anchors, never
   back-fires old slots, and never catch-up-fires slots from before its
   own existence. Consequence worth stating: a newly registered schedule
   first fires at its next *future* slot, never instantly upon
   registration.
3. **Due test:** materialize the next slot strictly after
   `max(last_attempted_slot, first_seen_at)` as a UTC instant (see slot
   materialization). Due iff that instant ≤ now.
4. **Coalescing:** if several slots have elapsed, consume them all and fire
   **once**, recording `coalesced_count`. A forward clock jump of hours or
   days therefore recovers with at most one fire per schedule.
5. **One run per schedule at a time:** due while the previous run is still
   live → consume **all** elapsed slots with a single
   `skipped: still running` record carrying `coalesced_count`, anchor
   advanced to the latest elapsed slot. One record per skip event, never
   re-emitted every tick, never one-per-slot spam during a long run.
6. **Present-but-not-firing entries consume elapsed slots silently** —
   anchor advances, nothing fires, nothing is recorded. This uniform rule
   covers paused entries, `not_executable` entries (invalid cron/tz/
   payload), and duplicate-id carriers alike: unpausing, repairing a
   broken entry, or resolving a duplicate never back-fires the slots that
   passed while it couldn't run.
7. **Launch-time re-validation:** immediately before firing, re-read the
   file and confirm the entry still exists, is executable, is not paused,
   the fingerprint is unchanged, **and the workspace kill switch is not
   engaged**; otherwise consume nothing this tick. Pause revocation
   therefore never depends on the watcher. The guarantee is
   **snapshot-based**: the fire launches from this final snapshot, and an
   edit landing in the snapshot-to-spawn window (milliseconds) may miss
   that one fire — stated, not hidden.

### Catch-up (workspace open, before the first tick)

- `catchup: false` (default): fast-forward the anchor —
  `last_attempted_slot := max(last_attempted_slot, now)` — so missed slots
  are consumed silently. The `max` keeps the anchor **monotonic**: after a
  backward clock jump plus restart, the anchor never regresses and
  already-consumed slots are never re-exposed.
- `catchup: true`: leave the anchor as persisted; the normal rule then
  produces exactly one coalesced fire for everything missed while closed,
  recorded with `trigger: catchup`. Fingerprint/tombstone reconciliation
  runs *first*, so a schedule edited (or deleted-and-recreated) while
  Valea was closed gets reset instead of catch-up-firing the old
  definition.

### Clocks, zones, DST

- **Slot materialization:** cron fields describe wall-clock times in the
  schedule's zone; each slot maps to a UTC instant. A wall time that does
  not exist (spring-forward gap) materializes at the first valid instant
  after the gap; a repeated wall time (fall-back) materializes only at its
  first occurrence (earlier UTC offset). All comparisons happen on UTC
  instants.
- **Forward clock jump:** bounded by coalescing — at most one fire per
  schedule.
- **Backward clock jump:** anchors now lie in the future; nothing fires
  until wall clock re-passes them. Predictable and documented; no
  discontinuity heuristics.
- **Host timezone change:** schedules with an explicit `timezone` are
  unaffected; host-zone-default schedules follow the new zone from the
  next tick.

### Run lifecycle & workspace switch

- Every launch and completion is **generation-bound** (the
  `verified_lifecycle` pattern): *asynchronous* run completions write
  records, outcomes, and notices only when the workspace generation at
  completion matches the one at launch — a run finishing after a switch
  cannot write into the new workspace's state. The one deliberate
  exemption: the **shutdown path itself** records `interrupted`
  synchronously while stopping runs, under the closing generation, as part
  of teardown — that write is the terminator acting, not a stale
  completion racing in later.
- **Command runs** are owned by a per-run process under the Workspace
  Runtime: on workspace close/switch the subprocess is stopped
  (`SessionServer.terminate` parity via ProcessRuntime) and the run is
  recorded `interrupted` on the shutdown path above.
- **Prompt runs** are ordinary sessions and already die with the workspace
  runtime; the run record is marked `interrupted` on the same path.
- A schedule deleted while its run is in flight: the run completes (or is
  interrupted by a switch); history is retained.
- **Prompt fires** compose the initial prompt as a fixed preamble + the
  schedule's prompt verbatim:

  > Scheduled run "<title>" (<schedule_id>) in <icm_name>. You are running
  > unattended; if you get blocked, record what's needed in tasks.json and
  > end the session.

  Session title: `<schedule title> — <date>`.
- **Failure:** session-spawn or command-spawn errors produce a `failed` run
  record + cockpit notice. No automatic retry — the next slot is the retry.
- **Global kill switch:** a workspace-level `scheduler_paused` flag
  (workspace settings, not a file sweep). While set, ticks keep running
  reconciliation and **consume elapsed slots silently for every entry**
  (anchors advance — disengaging never back-fires missed slots), but
  nothing fires and no run records are written; engaging/disengaging is
  audited; UI shows a banner. The final launch snapshot re-checks the
  switch (Firing rule step 7), so a switch engaged mid-tick still stops
  the fire.

### Consent & containment posture

Verified against current mechanics (Codex round 1): `RiskTier` is display
and envelope metadata by explicit contract — nothing in the approve/deny
path reads it — and `PermissionPolicy` auto-allows writes under
`write_paths`/`write_roots` regardless of session kind. The gate therefore
must be a policy rule, not a tier label:

- **The rule is enforced at BOTH layers, like the ICM secrets deny
  (policy + managedSettings):**
  - *PermissionPolicy, preceding the write-allow tier:* any write-kind
    candidate resolving to `schedules.json` at an enabled ICM root falls
    through to **:ask** even when covered by a write grant — "a broad
    grant can never buy schedule registration". Matching is
    candidate-based and casefolded like the ICM secrets deny
    (`SCHEDULES.JSON` caught).
  - *Managed-settings mirror — a best-effort SECOND layer, very likely
    inert under the pinned adapter.* **AMENDED (Task 5 review round 2)**:
    this bullet previously claimed the mirror was load-bearing because the
    renderer's `Write(<icm_root>/**)` **allow** rules "the harness honors
    without ever consulting Valea's callback" would short-circuit the
    policy rule. Three checks refute that premise:
    (a) `docs/notes/acp-launch-contract.md` — `managedSettings` is
    filtered **restrictive-only**, so permissive arrays including
    `permissions.allow` are *silently dropped* (`sdk.d.ts:1836-1858`), and
    the adapter wires `canUseTool` such that **every** tool call routes to
    Valea's callback (`acp-agent.js:2887`): the allow array never takes
    effect through this channel, so there is no allow for an `ask` to
    out-rank; (b) current harness docs — `Write(<path>)` rules are
    accepted but never consulted, path-scoped file checks being
    `Edit`/`Read` only (min version 2.1.210), hence the `Edit` twins; and
    (c) pattern anchoring — a single-leading-slash pattern anchors at the
    *settings source*, not the filesystem root, so the renderer also emits
    the `//<abs>` filesystem-absolute spelling alongside the plain one
    (strictly additive; a non-matching pattern is inert).
    **The enforcing layer is therefore `PermissionPolicy` on the ACP
    `request_permission` callback**, reached via the bare `Write`/`Edit`/
    `Bash` asks the posture already carries; the mirror is
    defense-in-depth for a harness that does honor it (and for the
    `Valea.Harness` `settings_path` channel a future harness may use).
    Documented precedence, for whichever entries do land
    (code.claude.com/docs/en/permissions): "Rules are evaluated in order:
    deny, then ask, then allow … rule specificity doesn't change the
    order" and "a matching ask rule prompts even when a more specific
    allow rule also matches the same call"; managed settings follow the
    same order. The **runtime probe stays mandated** (Task 9 acceptance):
    attempt an agent write to `schedules.json` in a granted-write ICM,
    confirm the dialog appears, record **which layer caught it**, and
    check the adapter's startup output for warnings about dropped or
    unparsed settings entries. If the probe shows the mirror inert AND the
    callback ever stops covering this, the fallback is a settings-level
    **deny** on `schedules.json` with registration moving to the
    UI/hand-edit path — fail closed, feature intact.
- **Candidate extraction: the move-shape question is closed by
  enumeration.** The single supported harness (claude-code via
  claude-agent-acp; `mcpServers` always `[]` by invariant) has **no
  move/rename file tool** — its file-writing tools are Write/Edit/
  NotebookEdit, whose `rawInput` path fields are exactly the four names
  `extract_paths/1` already reads; renames ride Bash (residual risk #6).
  An item with no extractable candidates already falls to `:ask`
  (verified — never a vacuous allow), so any future tool emitting
  move-shaped input lands on that safe floor until extraction is
  extended; the plan pins this against the shipped claude-agent-acp
  version.
- **Opaque shell writes** (`Bash` redirection onto `schedules.json`)
  cannot be path-classified; they fall to the harness/posture ask
  (verified: `Bash` sits in the managed-settings "ask" list) without the
  schedule-registration labeling — accepted residual risk #6.
- **`.valea/**` is write-denied** for agent sessions (deny, not ask);
  reads ordinary. See `.valea/` section.
- `RiskTier` additionally classifies `schedules.json` and `.valea/**` as
  "high" — dialog copy for the human deciding, which is all the tier ever
  was.
- The ask happens live in the session that attempts the write. A
  *scheduled* (unattended) session trying to write `schedules.json` parks
  on the ask and fires nothing — self-perpetuation fails closed.
- User-created schedules (UI RPC) and hand edits are the user acting — no
  gate. External writers: accepted risk #2.
- Command payloads execute outside any session posture with the user's
  full authority and no sandbox — the containment contract is exactly:
  exec-style spawn, allowlisted env, ICM-root cwd, timeout, output cap,
  always-ask registration, per-fire audit with the full command line, and
  the accepted-drift decision (risk #1).
- Scheduled *sessions* have identical PermissionPolicy posture to
  user-started sessions in the same ICM. A parked ask-gate surfaces as a
  `waiting` run + cockpit notice — approval happens in the normal
  transcript view.

## Scheduled-session visibility

- New session kind `"scheduled"` (beside Spec D's `"chat"`).
- Nav recent list and the "Show all" grouped pane **exclude** scheduled
  sessions by default; an "include scheduled runs" toggle reveals them.
- Primary access path is the **run history** under each schedule row: every
  run links to its transcript (prompt runs) or shows captured output inline
  (command runs). It's a normal session underneath — the transcript view is
  reused as-is.
- Cockpit notices keep parked/failed runs from being invisible: `waiting
  for approval` and `failed` runs are surfaced the day they happen.
- Sessions RPC/list filtering happens backend-side (kind filter param), so
  the nav store doesn't fetch-then-hide.

## UI surfaces

**Tasks nav item returns**, one route, two tabs: **Tasks** and **Schedules**.

Tasks tab:

- Merged across enabled ICMs, grouped by ICM with provenance (cockpit-
  section shape). Default filter **Today** (due today + overdue +
  `today`-flag + in_progress); toggles All / assignee / status.
- Quick-add composer (title + ICM picker, MRU default — Today quick-composer
  precedent). Checkbox completes. Row click opens a small editor (title,
  notes, due, today, priority, assignee, status). Overflow: drop, archive.
- `created_by: agent` badge. "Clear done" per ICM/all. Calm malformed-file
  note per ICM. Repair affordances for id-less/unknown-status entries.
  Empty states for no-ICMs and no-tasks.

Schedules tab:

- Row: title, human-readable cadence rendered from cron ("weekdays 07:30"),
  payload chip (prompt/command), next fire, last outcome, pause toggle,
  `created_by` badge, and the entry's **disposition** when not executable
  (the per-entry reason, e.g. "invalid cron", "duplicate id"). Expand →
  run history (fired_at, outcome, duration, trigger, coalesced count,
  transcript link or captured output).
- Actions: pause/resume + delete (file edits through the backend),
  **Run now** (debug affordance; identical fire path incl. launch-time
  re-validation; recorded as `trigger: manual`; does NOT advance the
  anchor — it is out-of-band). Run now is allowed for `executable` and
  `paused` entries (an explicit human click overrides a pause once) and
  **rejected with the displayed reason** for `not_executable`/duplicate
  entries — the strict-execution guarantee has no manual bypass.
- Header: **Pause all** switch + banner while active. Newly
  registered/changed schedules get a subtle highlight.

Cockpit (Today):

- Per-ICM section: a **tasks line** replacing `open_loops` — counts (due
  today / overdue / in progress) + top items (today-flag first, then due,
  then priority).
- Notices only for schedules: parked run, failed run, new/changed schedule
  registered ("next fire Mon 07:30"). No "next run" line on Today.

## Materialized briefing — `.valea/briefing.md`

`Valea.Mail.AgentsFile` pattern verbatim: template in `priv/`, materialized
on workspace activation and mount-enable, write-if-different, regenerated
header. Content:

- Both file contracts: field tables, allowed values, minimal valid
  skeletons for creating the files from scratch.
- The strictness warning: execution-control fields are validated strictly
  and fail closed — an invalid entry never fires and shows up as
  not-executable in the UI; write real JSON booleans.
- Invariants: mark done, never delete (Valea archives); ids are opaque
  short slugs you generate; never reuse an id; preserve fields you don't
  recognize; no run state in files; schedules fire only while Valea runs;
  `paused`/`catchup` semantics incl. "slots missed while paused are
  skipped for good — unpausing never back-fires"; one run per schedule at
  a time; editing cron/payload/timezone resets the schedule's anchor (no
  catch-up across edits; title edits don't); deleting and recreating an
  id resets it too; cron syntax incl. Vixie DOM/DOW rule + DST behavior.
- What to expect: writing `schedules.json` will ask the user for
  permission — that is the consent moment; `.valea/` is not writable by
  agents.
- The unattended-run convention (blocked → record in `tasks.json`, end).
- A **worked example**: an agent adds a task and registers a schedule,
  exact JSON before/after for both files.
- Pointer: run history/archival/pause-all live in the Valea UI.

Discovery: the `readme` field in each JSON file points at the briefing; the
seeded 3-layer CLAUDE.md template gains one pointer line; adopted ICMs are
never prose-edited — the adopt-flow copy mentions the briefing instead.
`today.json`'s brief loses `open_loops` guidance in the same template pass.

## RPC surface (UI-plane only; agents have no RPC path)

`list_tasks`, `create_task`, `mutate_task`, `archive_done`,
`list_schedules`, `create_schedule`, `mutate_schedule`, `delete_schedule`,
`run_schedule_now`, `schedule_run_history`, `set_scheduler_paused`. All
generation-guarded like every mutating workspace RPC (verified_lifecycle).
Cockpit extension rides the existing today payload. List RPCs return
per-ICM parse status **and per-entry dispositions** (schedules) so the UI
can render calm malformed notes and per-entry reasons.

## Audit

Audited: every fire/skip/completion/failure (with fingerprint, trigger,
session id or output ref — command fires record the full command line),
watcher-observed `schedules.json` changes (diff summary — agent
registrations belong in the log), UI task mutations, archive sweeps,
pause/resume incl. Pause-all. Deliberately not audited: agent edits to
`tasks.json` (transcript territory; accepted risk #4 covers destructive
rewrites). Run-history rows are keyed by `(icm_id, schedule_id)` and
survive schedule deletion and mount renames.

## Error handling (summary)

| Failure | Behavior |
|---|---|
| Malformed `schedules.json` | Fail-safe: no fires from the file; calm UI note; one audit notice per content-hash |
| Invalid execution field on one entry | That entry `not_executable` with visible reason; never fires; elapsed slots consumed silently (repair never back-fires); others unaffected |
| Pause-all engaged | Nothing fires; anchors keep advancing silently; disengage never back-fires; launch snapshot re-checks the switch |
| Duplicate schedule ids | All carriers excluded from execution, visible reason; order never decides |
| Malformed `tasks.json` | Calm UI note; ledger treated as empty for display; file untouched |
| Session/command spawn error | `failed` run record + cockpit notice; no auto-retry |
| Command runaway | Timeout kill (10 min), `timed out` outcome; output capped 256 KiB |
| Previous run still going | One `skipped: still running` record per skip event (coalesced count); anchor advances to latest elapsed slot |
| App closed over slots | Consumed silently on open (anchor := max(anchor, now)) unless `catchup: true` (one coalesced catch-up fire) |
| Forward clock jump | Coalesced: at most one fire per schedule |
| Backward clock jump | Quiet until wall clock re-passes anchors (monotonic — survives restarts); documented |
| Schedule id vanishes from a parseable file | Tombstone; any reappearance (even identical) resets anchors |
| Slots elapse while paused | Consumed silently; unpausing never back-fires |
| Run now on invalid/duplicate entry | Rejected with the entry's displayed disposition reason |
| Workspace switch mid-run | Command subprocess stopped, prompt session dies with runtime; run recorded `interrupted`; completion writes generation-bound |
| Same ICM in two workspaces | Anchors are per-workspace; a slot can fire once per workspace — accepted risk #3 |
| Schedule deleted mid-run | Run completes; history retained |
| Definition edited (fingerprint change) | Anchor reset to observation time; no catch-up across the edit |
| Duplicate task ids | First wins for addressing (tasks are inert); calm note |
| Valea write conflict (file changed under a patch) | Re-read + re-apply, 3 retries; entry gone → conflict surfaced, nothing written |

## Non-goals

No OS-timer management (launchd/systemd/Task Scheduler), no agent-facing
RPCs or MCP tools, no task dependencies/subtasks/recurrence-on-tasks, no
per-day plan files, no multi-assignee or team semantics, no retry policies
on schedules, no headless-app background daemon, no notification center
beyond cockpit notices, no workspace-level (non-ICM) schedules — mail/
calendar engines keep their own loops. No command sandbox and no script
hash-pinning (accepted risk #1); no cross-workspace scheduler lease
(accepted risk #3); no destructive-task-delta detection in v1 (accepted
risk #4); no ledger lock files (accepted risk #5).

## Testing

- Backend: cron parser vectors (Vixie DOM/DOW, aliases, DST spring/fall
  materialization); scheduler determinism with injected clock + fake
  payload runner (fire, coalesce, coalesced still-running skip, catchup
  true/false with monotonic `max` anchor across a backward-jump + restart,
  fingerprint reset on definition change, fingerprint STABLE across
  title/`paused` edits, tombstone on id-vanish + reset on identical
  recreation, silent slot consumption for paused AND non-executable AND
  duplicate entries (repair/unpause never back-fires), launch-time
  re-validation catches a pause landed mid-tick AND a mid-tick kill
  switch, run-now gating incl. no anchor advance, pause-all silent
  consumption, forward/backward clock jumps); strict-field
  fail-closed matrix (`paused` string, bad tz, bad cron, missing id,
  duplicate ids, escaping `context_doc` → dispositions); leniency
  round-trips incl. unknown-field preservation; per-ICM writer
  serialization + conflict-retry (patch re-applied against changed file;
  vanished entry → **`{:error, :not_found}`** — *implementation
  reconciliation (Task 1, ruled acceptable): this line said "conflict"; the
  distinct atom is strictly more informative and nothing is written either
  way*); archive snapshot-hash identity (crash
  re-append dedupes on read), snapshot-conditional prune (reopened entry
  survives), crash re-convergence, partial-trailing-line tolerance; run records generation-bound across a
  simulated switch (shutdown-path `interrupted` exemption pinned); command
  run stopped on workspace close; PermissionPolicy always-ask carve-out
  for `schedules.json` (direct write, move-shape candidates once
  extracted, casefold, empty-candidates→ask floor) + `.valea/**`
  write-deny + RiskTier stamps + managed-settings mirror rules incl. a
  runtime probe pinning ask-beats-broader-allow precedence against the
  shipped harness; briefing materialization write-if-different; RPC
  generation guards; session-kind filtering.
- Frontend: component tests for both tabs (filters, quick-add, pause,
  dispositions, run history, run-now), cockpit tasks line + notices,
  malformed-file notes, task repair affordances, nav exclusion of
  scheduled sessions + debug toggle.
- Browser test plan: new Tasks/Schedules section in
  `docs/testing/browser-test-plan.md` — quick-add → file appears;
  hand-edit file → UI updates; agent registers schedule → ask-gate →
  row appears + cockpit notice; invalid entry shows disposition; run-now →
  transcript reachable; pause-all; archive sweep.

## Open items / accepted trade-offs

- Nothing fires while Valea is closed — stated in UI copy. The user's
  existing systemd timers remain a valid pattern outside Valea; Valea does
  not try to absorb them.
- Accepted residual risks #1–#6 enumerated under Decisions (the
  optimistic-concurrency residual is #5; opaque-shell ask labeling is #6).
- `today.json` keeps `notes`/`prepared` for now; full retirement is a
  future cleanup once tasks prove out.
