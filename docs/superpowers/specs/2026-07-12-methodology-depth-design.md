# Methodology Depth — Teach-the-Assistant Loop (ICM Spec B)

**Date:** 2026-07-12 · **Status:** approved design, pre-plan
**Depends on:** 2026-07-10-agent-slice-design.md (queue/audit/session
machinery), 2026-07-12-icm-mounts-design.md + 2026-07-12-icm-by-reference-design.md
(mount model, physical-path vocabulary, containment). Implements the
"memory-update suggestions" the agent-slice spec explicitly deferred.

## Goal

Close the teaching loop from the vision's daily-loop step 5: the user
teaches the assistant — tone, policies, pricing, decisions — and the
assistant gets better because the context gets better. Knowledge flows
into ICM through three doors, every change is approved, and rejections
start carrying a why:

1. **Chat** — conversational teaching. The agent edits the page directly
   with its native tools; the user approves a real diff in the moment.
2. **Workflow runs** — the agent notices stale/missing/contradictory
   knowledge mid-job and leaves a memory-update proposal in the queue
   alongside its main output.
3. **Reflection** — a "Distill decisions" workflow mines recent
   approvals and rejections and proposes durable decision-log entries
   and page corrections, also through the queue.

## The hybrid split (the load-bearing decision)

Direct edits and queue proposals each win where the other loses:

- **Background origins (workflows, reflection) require the queue.** No
  user is present; "AI prepares, human approves in the morning" needs
  prepared-but-unapplied changes sitting durable and reviewable. A live
  dialog cannot substitute.
- **Chat keeps direct edits.** The user is right there; the ask-gate
  dialog upgraded with a diff is the same interaction as a queue card at
  a fraction of the machinery, and direct file editing is what coding
  harnesses do best (Principle 5). A chat-approved edit needs no
  decided-history distillation — it already became memory — and
  "rejection with reason" in chat is simply the conversation: the user
  says why, the agent re-proposes in the same turn.

No chat-origin queue proposals, no session staging grants for chat, no
inline queue cards. The two review surfaces are honest about their
contexts: live diff dialog when you're present, queue card when you
weren't.

## Harness posture (unchanged, and why this design is harness-agnostic)

Nothing here asks the harness for anything beyond reading and writing
files. Over ACP, Valea answers each tool call's permission request from
the policy: a run's staging path → allow (write grant), a chat write to
a mount page → ask (now with diff), outside → deny. Any ACP harness that
can write a file can emit proposals; the managed `.claude/settings.json`
layer stays Claude-Code-specific defense in depth, exactly as today.

## 1. Chat teaching — the upgraded ask dialog

The existing ask-gate becomes a real review surface; ask/deny/allow
semantics do not change.

- The ACP tool-call stream already carries an Edit/Write's old/new
  content. The permission dialog renders it as a line diff — path, mount
  name, old → new. Writes without diff data fall back to today's
  display.
- The `permission_requested` payload gains a server-derived **risk
  tier** for the target (same classifier as §3): behavior-bearing mount
  files (`Workflows/*.md`, `AGENTS.md`, `icm.yaml`) → `high`, rendered
  terracotta with "changes how your assistant behaves"; other mount
  content → `medium`; non-mount targets → unclassified (dialog as
  today). The tier is display guidance — the decision remains the
  user's.
- Decisions stay audited as today (`permission_asked`/`answered`).

## 2. Workflow proposals — staged markdown + thin manifest

The agent authors markdown as markdown, never markdown-inside-JSON. A
memory proposal is a sibling pair in the run's already-granted staging
dir:

```
queue/staging/<run_id>/proposals/pricing-update.md     ← full new page content
queue/staging/<run_id>/proposals/pricing-update.json   ← manifest
```

Manifest (`memory_update/v1`):

```json
{
  "schema": "memory_update/v1",
  "target_path": "mounts/company/Offers/Pricing.md",
  "base_sha256": "<hex of the page bytes as the agent read it, or null>",
  "reason": "Hourly rate changed to 150€ per the rejected draft's feedback",
  "sources": ["mounts/company/Offers/Pricing.md", "queue digest"]
}
```

- `target_path` uses the physical vocabulary (Spec A2): workspace-
  relative for embedded mounts, resolved-absolute for external mounts.
- `base_sha256: null` means "create this page"; at apply the target must
  not exist.
- Content is the **full new page**; the UI computes the display diff.
- A run may emit its primary `proposal.json` (email draft, unchanged),
  zero or more memory pairs, or only memory pairs (reflection). The
  run's prompt names what the contract calls for.

## 3. Finalize — one queue item per pair, server-owned trust fields

`finalize/2` additionally globs `proposals/*.json`; each valid pair
becomes its own pending item with id `<run_id>-m1`, `-m2`, … (lexically
sortable, safe basenames). Server-side, never agent-claimed:

- **Containment:** `target_path` must resolve (symlink-hardened) inside
  an **enabled mount**. The workspace shell — root `AGENTS.md`,
  `MOUNTS.md`, `config/`, `queue/`, `sources/`, `logs/` — is
  structurally outside every mount and therefore never a valid target.
  Violations are audited `invalid_proposal`; no queue item.
- **Risk tier:** derived from the target path (classifier of §1),
  overwriting anything the manifest claims. `high` for behavior-bearing
  files, `medium` otherwise.
- **Self-contained envelope:** finalize inlines the content file into
  the `queue_item/v1` envelope — `payload.kind: "memory_update"`,
  `proposed_action: {type: "apply_page_content", target_path,
  base_sha256, content_markdown}`. The JSON-escaping is done by the
  server; a pending item stays one reviewable file, like today.
- An orphaned `.json` (no sibling `.md`) or orphaned `.md` is an audited
  `invalid_proposal`. Zero proposals of any kind → the existing
  no-proposal outcome.

## 4. Apply executor — Valea writes, hash-guarded

`Queue.approve` gains a second execute arm for `apply_page_content`,
with the same claim/revision discipline as drafts:

1. Re-check enabled-mount containment (the editor's symlink-hardened
   resolve-real gate against the mount root).
2. **Base-hash guard:** current page bytes must hash to `base_sha256`;
   for a create, the target must not exist.
3. Match → atomic tmp+rename write (mkdir -p of parents, inside the
   mount only), audit `action_executed` with the target path, terminal
   rename to `approved/`.
4. Mismatch — page edited since proposal, mount disabled, external
   mount unreachable, create-target now exists — → **nothing executes**;
   the claimed item is renamed back to `pending/`, `apply_conflict` is
   audited with the reason, and the card explains "page changed since
   this was proposed — reject it or re-run the workflow."

Crash recovery extends `recover/1` deterministically: a `memory_update`
item stuck in `processing/` is finished (terminal rename + audit with
`recovered: true`) iff the target's current bytes hash to the proposed
content — the apply already happened; otherwise it is handed back to
`pending/`. `mailbox_ops` remain email-only (the existing kind guard).
The decided-envelope v2 upgrade additionally stamps `decided_at` (both
kinds) — the reflection window needs decision time, not proposal time.

## 5. Rejection reasons

`reject/2` accepts an optional one-line free-text reason (both item
kinds), stamped into the decided envelope during the v2 upgrade
(`decision: {reason}`) and included in the `item_rejected` audit entry.
The queue UI shows a skippable single-line field on reject. This is the
queue's teaching signal; chat needs none — the conversation is the
signal.

## 6. Reflection — the "Distill decisions" workflow

An ordinary, inspectable contract shipped in the starter mount
(`Workflows/Distill decisions.md`; manual trigger, `risk_level:
medium`, approval required — its outputs are §2 proposals). Run from a
"Distill recent decisions" action on Today and the Workflows page. No
scheduler this phase.

- **Input — a server-compiled digest.** Valea reads the decided
  envelopes with `decided_at` in a fixed 30-day window (pre-Spec-B
  envelopes without the stamp are excluded) and renders one markdown
  digest: per item — kind, title, workflow,
  decision, date, rejection reason. The digest is written into the
  run's staging dir and named as the run's input.
- **Per-run staging read grant:** the run's read roots additionally
  include its own staging dir — a run may always read what it may
  write. The read boundary **never widens to `queue/`**; the digest is
  self-contained.
- The runner gains a variant accepting server-generated input (the
  digest) in place of a workspace input file; run identity, staging,
  finalize, and audit are otherwise identical.
- The contract instructs the agent to check the mount's existing
  decision pages first (no re-proposing what is already recorded), to
  distill durable decisions into them, and to propose corrections to
  any page the decisions contradict.

## 7. Decision pages — a convention, not a mechanism

The starter template mount gains a `Decisions/` section (chronological
pages, e.g. `Decisions/2026.md`: date, decision, why, source), with the
convention documented in the mount's own `AGENTS.md` — the methodology
travels with the mount and works for a bare Claude Code session with no
Valea present. Entries arrive through ordinary §2 proposals; the user
edits them like any page. No mechanical log: `logs/audit.jsonl` already
records what happened; decision pages record what it means.

## 8. UI

- **Queue card (`memory_update`):** mount + page path, reason, sources,
  line diff of the current page vs proposed content (computed
  frontend-side from the envelope's content and the page read via the
  existing RPC), "page changed since proposed" warning when the base
  hash no longer matches, terracotta risk banner on `high`, link into
  Knowledge.
- **Reject dialog:** optional reason field, both kinds.
- **Chat ask dialog:** diff + risk banner per §1.
- **Today cockpit:** memory proposals ride the existing prepared-items
  card; plus the "Distill recent decisions" action.
- **Decided history:** shows the applied target path and the rejection
  reason alongside existing fields.

## Trust & product framing

The first-run promise gains its closing clause: the assistant not only
prepares work — it learns, visibly. Copy: "Suggested memory update",
"Why this?", "Nothing in your business memory changes without your
approval." The risk tier makes the sharpest edge explicit: a proposal
touching `Workflows/` or `AGENTS.md` is approving future agent
behavior, and the card says so in plain words.

## Error handling

| Failure | Behavior |
| --- | --- |
| Invalid/orphaned proposal pair | Audited `invalid_proposal`; no queue item |
| Target outside enabled mounts / shell target / traversal / bad hash format | Rejected at finalize, audited; never pending |
| Base hash mismatch at approve | No write; item back to `pending/`, `apply_conflict` audited; card explains |
| Mount disabled or external ref unreachable at approve | Same conflict path |
| Create-target already exists | Same conflict path |
| Crash mid-apply | `recover/1`: target bytes hash equals proposed content → finish approval; else back to `pending/` |
| Reflection window empty | Run completes with no proposals; audited outcome; honest UI message |
| Stray agent files elsewhere in staging (outside `proposal.json` and `proposals/`) | Ignored by finalize; orphaned files *inside* `proposals/` are audited per §3 |

## Testing

- **Finalize:** pair globbing, N items per run, derived item ids,
  server risk tiering, containment rejections (shell, traversal,
  disabled mount, external), orphaned pairs, content inlining.
- **Apply executor:** hash-guard matrix (edit, create,
  conflict-on-change, mount-disabled, external target, create-exists),
  atomic write, parent creation stays inside the mount, conflict
  hand-back to pending, crash-recovery idempotency via content hash.
- **Rejection reasons:** persisted in decided envelope + audit, both
  kinds; absent reason stays absent.
- **Digest:** window by `decided_at`, reasons included, deterministic
  rendering; session `policy_ctx` asserted to include the staging read
  grant and exclude `queue/`.
- **Chat dialog:** risk-tier classification unit tests; frontend diff
  computation and card/conflict states per the pure-extraction pattern.
- **End-to-end acceptance:** see below.

## Acceptance scenario

Teach a price change in chat → the ask dialog shows the page diff with
the mount name → approve → the page is updated and audited. Run inquiry
triage on a message that contradicts a policy page → the queue holds
the draft **and** a memory-update proposal citing the page → reject the
draft with a reason ("too pushy") → run "Distill recent decisions" →
the queue holds proposals updating a `Decisions/` page (citing the
rejection reason) and correcting the stale page → approve both → the
decision page exists in the mount, the correction is applied, and the
full chain is in the audit log. Edit the target page manually before
approving a pending proposal → approve surfaces the conflict and the
item returns to pending instead of clobbering. "Open the hood" shows
the proposal pair, the digest, and the decided envelopes as plain
files.

## Non-goals this phase

Edit-before-approve, scheduled/automatic reflection runs, chat-origin
queue proposals, multi-page changesets, page deletion/rename via
proposals, page version history, snooze, mining chat transcripts.
