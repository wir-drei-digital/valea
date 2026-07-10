# Agent Prototype Slice — Design (Phase 3)

**Date:** 2026-07-10 · **Revised:** 2026-07-10 (v2, after external review)
**Status:** Draft — pending user review
**Scope:** Sub-project 3 — the full AI-prepares-human-approves loop with zero
external integrations: ACP agent sessions in the workspace, chat UI, workflow
execution on the seeded mock email, approval queue, audit log, Today card.

## Context

Phases 1–2 shipped the workspace lifecycle, the Paper & ink shell, and a fully
editable ICM with a deterministic markdown round-trip. This phase makes Valea
an *agentic* OS: a real agent works inside the user's workspace folder, under
the trust rules the product is built on (VISION.md principles 4–5).

Grounding:
- **ACP** (Agent Client Protocol, agentclientprotocol.com, protocol version 1)
  is the adapter boundary between Valea and agent harnesses. Claude Code
  connects through **`@agentclientprotocol/claude-agent-acp`** (binary
  `claude-agent-acp`, v0.58.x, requires Node 22+; the `@zed-industries/
  claude-code-acp` package legend uses is deprecated in favor of this rename).
- **The ICM paper** (Van Clief & McDermott, arxiv.org/html/2603.16021v2)
  informs the structure. Valea **adapts** the paper rather than implementing
  it literally — see §ICM layer mapping.
- **Legend** (read-only donor) contributes its ACP core as an **architectural
  donor, not vendored behavior**: the pure-codec/process split, NDJSON
  framing, stderr separation, watchdog, and timeline patterns carry over;
  the protocol surface is updated to current ACP (see §Codec).

Product decisions made in brainstorming (v1) and revised after review (v2):
- **Session cwd = workspace root**; chat + workflow run both in scope;
  Claude Code only (the harness seam stays); transcripts are workspace
  files; auth delegated to the user's own Claude login with a guided
  doctor; workflows become ICM pages at `icm/Workflows/*.md`; multi-ICM =
  workspaces now (switcher ships) + ICM mounts later (recorded in
  VISION.md).
- **File-first resources (product principle, decided 2026-07-10):** every
  resource the agent consumes or produces is a plain file in the workspace —
  today's mock email, proposals, drafts; later synced calendar events and
  real mail (future integrations are sync-to-files engines writing into
  `sources/`). The file tree **is** the agent's API: no custom tools, no
  custom MCP servers — coding harnesses are used at what they do best.
  `session/new`'s required `mcpServers` param is always `[]` by principle,
  not by phase limitation.
- **v2 revisions:** explicit trust model instead of implied confinement;
  managed Claude settings file so operations actually reach Valea's
  permission callback; `allow | deny | ask` policy with hard-deny
  precedence and no blanket read root; harness executable moved out of
  workspace control into app config; authenticated loopback control
  plane; server-owned run identity and exact output paths; hardened
  approval (revision hash, atomic claiming, idempotent execution, crash
  recovery, full-draft review); workspace-scoped runtime supervisor with
  generations and an idempotent migration; current-ACP corrections
  (resume/load, config options, cancellation outcomes, clientInfo,
  option kinds).

## Trust model (explicit)

The Claude adapter and the Claude Code runtime are **trusted infrastructure**
running as the user, on the user's machine, with the user's own credentials.
Valea does **not** claim hard confinement of the agent process (no OS
sandboxing this phase — recorded as a later hardening option). What Valea
provides is **defense-in-depth for an honest-but-fallible agent**:

1. A **managed Claude settings file** routes risky operations to Valea's
   permission callback instead of silent auto-approval (§Permissions).
2. The **ACP permission policy** decides allow/deny/ask with hard-deny
   precedence and audits every decision.
3. The **server owns all identity and execution**: the agent only proposes;
   queue items are validated, wrapped, and executed by the backend.
4. The **audit log + transcript files** make every action reconstructable.

The threat this phase defends against is agent *mistakes* (wrong file, wrong
scope, over-eager tool use) and unreviewed consequences — not a malicious
adapter binary.

## Workspace files

### AGENTS.md / CLAUDE.md (paper Layer 0/1, combined — a Valea adaptation)

Seeded at the workspace root. **`AGENTS.md` is canonical**; `CLAUDE.md`
contains only `@AGENTS.md` (officially supported import), so Claude Code and
other harnesses read the same truth. Valea deliberately combines the paper's
Layer 0 (root instructions) and Layer 1 (workspace routing) into one file at
this workspace size. Content, plain language:

1. **Who you work for & what this folder is** — one paragraph stating the
   file-first deal (everything you work with is a plain file in this
   folder; you need no other tools), then the
   workspace map: `icm/` is reference memory (read what a job's Inputs
   name — do not slurp the tree); `icm/Workflows/` are your job contracts;
   `sources/` is read-only input; you write **only** where the current job's
   instructions name an exact output path; `logs/`, `secrets/`, `.claude/`
   and the database are off-limits. Written as an enumeration of ICM roots
   (today: one) so mounts can extend it later.
2. **Hard rules** — never send anything; never delete; never edit `icm/`
   pages (memory-update suggestions are a later feature); one proposal per
   workflow run; when unsure, stop and say so rather than guessing.
3. **The proposal contract** — the exact payload schema (below), with one
   worked example.

### Managed Claude settings (`.claude/settings.json`)

ACP agents only *may* request permission — Claude Code auto-runs reads and
anything its own modes/rules approve never reaches the client callback. So
Valea **writes and owns** `.claude/settings.json` in the workspace
(regenerated at every session start; documented in AGENTS.md as
machine-managed; listed in the workspace gitignore):

- **deny**: read/write of `secrets/**`, `logs/**`, `.claude/**`, `.git/**`,
  the SQLite files (`app.sqlite*`), and network tools (`WebFetch`,
  `WebSearch`).
- **ask**: all file writes/edits, `Bash`.
- **allow**: reads elsewhere inside the workspace.

Sessions are started in the adapter's default permission mode (never
`bypassPermissions`). This is what makes the ACP policy *reachable*; the
policy below is then the deciding layer.

### The proposal payload (`proposal/v1`) and queue item (`queue_item/v1`)

The **agent writes only a proposal payload** to the exact staging path its
run names (§Runner):

```json
{
  "schema": "proposal/v1",
  "kind": "email_draft",
  "title": "Reply to Priya Nair — coaching inquiry",
  "summary": "Good-fit inquiry. Drafted a warm reply proposing a discovery call.",
  "sources": [
    "sources/mail/normalized/priya-nair-inquiry.json",
    "icm/Offers/Founder Coaching Package.md"
  ],
  "proposed_action": {
    "type": "create_email_draft",
    "to": "priya@example.com",
    "subject": "Re: Question about leadership coaching",
    "body_markdown": "…"
  },
  "reasoning": "Classified good-fit because …"
}
```

The **server** validates it and writes the canonical queue item
`queue/pending/<run_id>.json` — a server-owned envelope wrapping the
payload:

```json
{
  "schema": "queue_item/v1",
  "run_id": "<server-generated>",
  "session_id": "<valea session id>",
  "acp_session_id": "<agent-owned id>",
  "workflow": "icm/Workflows/New Inquiry Triage.md",
  "workflow_hash": "<sha256 of the workflow page at run start>",
  "input": "sources/mail/normalized/priya-nair-inquiry.json",
  "input_hash": "<sha256>",
  "risk_level": "medium",
  "created_at": "2026-07-10T09:14:00Z",
  "payload": { …proposal/v1… }
}
```

`risk_level` and required approval come from the workflow frontmatter
(server-read), never from the agent. Invalid payloads surface as a calm
"the assistant produced something I couldn't read" state (raw file one
toggle away), never a crash. MVP action vocabulary: `create_email_draft`.

### Workflow pages (paper Layer 2, hosted in the ICM — a Valea adaptation)

The template's four `workflows/*.yaml` convert to `icm/Workflows/*.md`; the
root `workflows/` folder disappears. Hosting Layer 2 inside the reference
tree is a deliberate product adaptation (one tree, one editor, one nav) and
is documented as such in ARCHITECTURE.md. Format — YAML frontmatter
(machine) + markdown body with **Inputs / Process / Outputs** sections
(the paper's contract shape):

```markdown
---
enabled: true
trigger: { type: manual, source: email.selected }
sources:
  - { id: current_email, type: email, required: true }
  - { id: offer, type: icm, path: "icm/Offers/Founder Coaching Package.md" }
risk_level: medium
approval:
  required: true
  reason: Email replies must be reviewed before sending.
  actions: [create_email_draft]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# New Inquiry Triage

Classifies a new email inquiry and drafts a reply for review.

## Inputs

| Input | Where |
| --- | --- |
| The inquiry email | named by the run |
| Offer, tone, policy, pricing pages | `sources:` above |

## Process

1. Summarize the incoming inquiry.
2. Classify: good-fit, unclear, not fit, or spam.
3. Draft a warm reply using the tone guide and the relevant offer.

## Outputs

One `proposal/v1` payload at the exact path the run names. Do not send.
```

**Only New Inquiry Triage ships `enabled: true`** — the other three seed
pages are `enabled: false` (their triggers aren't supported by this slice;
the Workflows UI shows them as "not active yet").

VISION.md amendments this phase: principle 3 — workflows are "inspectable
markdown contracts with a YAML header"; principle 5 gains the file-first
integration rationale (files are the agent's API; no custom tools or MCP
servers); roadmap items 4–5 (Mail, Calendar) are reworded as sync-to-files
engines landing in `sources/`; the roadmap gains the ICM-mounts item.

### harnesses.yaml — removed from the template

A workspace-controlled command would let any opened folder execute an
arbitrary binary. **Harness executable configuration moves to trusted app
config** (`Valea.App.Config`, OS app-data): default command
`claude-agent-acp` resolved from PATH to an absolute path; a custom
executable requires explicit user consent, recorded in app config, and the
UI shows the resolved absolute path before first use. The workspace
migration ignores an existing `harnesses.yaml`.

## ICM layer mapping (documented adaptation)

| Paper | Valea |
| --- | --- |
| Layer 0 root instructions + Layer 1 routing | `AGENTS.md` (+`CLAUDE.md` import) — combined, one file |
| Layer 2 stage contracts | `icm/Workflows/*.md` — hosted inside the reference tree |
| Layer 3 stable reference | `icm/` (everything else) |
| Layer 4 working artifacts | `queue/`, `sources/` |
| — (not an ICM layer) | `logs/` — operational record (transcripts, audit) |

## Frontmatter passthrough (ICM/editor change)

`Valea.ICM` learns to split an optional leading `---\n…\n---\n` block:

- `icm_page` returns a new `frontmatter` field (parsed map, null when
  absent) alongside `content`/`prosemirror`; the ProseMirror conversion
  sees **only the body**.
- `save_page` re-reads the file under the existing hash guard, splits the
  current frontmatter, serializes the body, and writes `frontmatter <>
  body` — the frontmatter block reattached **byte-identical**. The
  determinism contract extends: frontmatter never churns; pages without
  frontmatter behave exactly as today.
- Frontmatter is **not editable in-app** this phase; `PageMeta` displays
  the parsed fields read-only. The token-cost estimate counts the whole
  file.
- The Phase-2 round-trip suite gains frontmatter fixtures (all four
  workflow pages round-trip byte-identically).

`Valea.ICM.References` scans `icm/Workflows/*.md` instead of
`workflows/*.yaml` — same literal string scan, wildcard pairs included.

## Backend architecture

New deps: `erlexec`, `yaml_elixir`. **Flagged risk, verified first:**
erlexec ships a C port binary — its survival inside the Burrito-packaged
sidecar must be proven **in the actual packaged .app**, including
process-group cleanup (stopping a session kills the adapter's whole
process tree), before anything builds on it (plan Task 1 territory).

### Workspace runtime supervision & generations

All workspace-bound processes move under one **`Valea.Workspace.Runtime`
supervisor** started by the Manager on open and **fully terminated before
a switch completes**: the file watcher, the agent sessions supervisor,
queue, and audit. The Manager stamps each open with a monotonic
**workspace generation**; every runtime process and every broadcast event
carries it, and **mutating RPCs include it** — a stale generation returns
`workspace_changed` instead of acting on the wrong workspace.

### Workspace migration (idempotent)

The workspace gains a version marker (`config/workspace.yaml`,
`version: 2`; absent = version 1). On open, an idempotent migration brings
older workspaces up: create `AGENTS.md`/`CLAUDE.md` if missing, convert
root `workflows/*.yaml` to `icm/Workflows/*.md` (skip existing targets),
create `queue/staging/` and `queue/processing/`, write the managed
`.claude/settings.json`, write the version marker. Scaffold's required-dir
list is updated (root `workflows/` no longer required). Migrations never
delete user files.

### Harness seam

- `Valea.Agents.CommandSpec` — `%{cmd, args, env, io: :pipes}` with `cmd`
  an **absolute path**, argv passed without a shell.
- `Valea.Harness` behaviour — `definition/0` + `acp_command(opts)`.
- `Valea.Harnesses.ClaudeCode` — the only implementation: resolves the
  executable from app config (§harnesses.yaml above).
- **Minimal environment**: sessions get an explicit allowlist (`HOME`,
  `PATH`, `USER`, `LANG`/`LC_*`, `TMPDIR`, plus Claude/Anthropic auth
  variables when present) — never the backend's environment
  (`SECRET_KEY_BASE` etc. must not leak into the subprocess).

### `Valea.Acp.Connection` (codec — legend as donor, protocol current)

Pure functions over a struct: `{state, render_items, reply_frames,
effects}`. Carried from legend: NDJSON framing (1 MiB incomplete-line cap,
undecodable lines logged and dropped), stderr never enters the decoder,
tool-call merge by id (diff extraction, output capped 64 KiB tail-kept),
message/thought accumulation, plan items, `-32601` for unsupported
agent→client requests. Updated to current ACP:

- `initialize` sends `protocolVersion: 1` **and `clientInfo`**
  (`{name: "valea", version}`); the negotiated version is validated
  (mismatch → handshake failure with a doctor-readable reason).
- Session start preference: **`session/resume`** when
  `sessionCapabilities.resume` is advertised (no replay) → **`session/
  load`** when `loadSession` is advertised (full replay; the reducer
  dedups replayed messages by `messageId` against the persisted
  timeline) → else `session/new`. Both the **Valea session id and the
  agent-owned ACP session id are persisted separately** (transcript
  metadata line).
- Config: **`session/set_config_option`** (`configId`, `value`) with
  `config_option_update` notifications; modes/models are config options
  with `category: "mode"|"model"`. `session/set_mode` kept only as a
  deprecated fallback when the agent exposes no config options;
  `session/set_model` is not used. `session_info_update` and
  `usage_update` notifications are reduced to meta render items (session
  title; token usage shown as a quiet meta line).
- **Cancellation**: `session/cancel` first answers **every pending
  permission request** with `{outcome: {outcome: "cancelled"}}`, then
  clears them.
- Permission answers select options **by `kind`** (`allow_once` /
  `reject_once`), never by assuming option ids.

### `Valea.Agents.SessionServer`

One GenServer per session (`restart: :temporary`, DynamicSupervisor +
Registry by session id, under the workspace runtime). Responsibilities:

- Spawn the adapter via erlexec (`io: :pipes`, `cd:` workspace root,
  minimal env). stderr logged, never decoded.
- 30 s handshake watchdog → `:failed` with a doctor-readable reason.
- Feed stdout to the codec; write reply frames; execute effects.
- **Append every timeline item to `logs/sessions/<id>.jsonl` as it
  arrives** (line 1 metadata: `{schema: "session/v1", id, acp_session_id,
  kind: "chat"|"workflow", run_id, title, workflow, harness, generation,
  started_at}`; then `{seq, item}` lines). The file is canonical; a crash
  loses nothing.
- Broadcast `{seq, item}` / status / exit on PubSub topic
  `agent_session:<id>` (generation-stamped).
- Run permission requests through the policy before the UI sees them.
- One-turn-at-a-time prompt queue.
- On exit the server stays up (transcript viewable) until workspace close;
  after restart the file alone serves replay.

Session ids are backend-generated (`<UTC-timestamp>-<random-suffix>`).

### `Valea.Agents.PermissionPolicy`

Pure: `(permission_params, policy_ctx) -> {:allow, option} | {:deny,
option} | :ask` where `policy_ctx` carries **lists** of roots (mount-ready)
plus the session's write grant. Precedence: **deny → allow → ask**, and
anything unclassifiable is `:ask`.

- **Deny (hard, always):** any path under `secrets/`, `logs/`, `.claude/`,
  `.git/`, the SQLite files; network tools. (Defense-in-depth behind the
  settings file.)
- **Allow (read):** read-kind calls whose paths all fall inside the
  declared reference roots — `icm/`, `sources/`, `prompts/`, and the root
  instruction files. **Not** a blanket workspace-root allow.
- **Allow (write):** only for workflow runs, and only the run's **exact
  staging path** (§Runner). **Chat sessions have no automatic write
  root** — every write asks.
- Path checks resolve symlinks (real-path containment, shared with a
  hardened ICM chokepoint helper) before comparing against roots.
- Every decision — allow, deny, and ask alike — is audited. `:allow`
  selects the `allow_once` option; never "always allow".

### `Valea.Agents.Doctor`

RPC returning per-check status (ok / failed / unknown) + copyable remedy:

1. Node 22+ available.
2. Adapter executable resolves (app config / PATH) and answers
   `--version` — remedy `npm install -g @agentclientprotocol/claude-agent-acp`.
3. Auth: `claude-agent-acp --cli auth status` — remedy
   `claude-agent-acp --cli auth login --claudeai`. No separate `claude`
   executable is required.

### `Valea.Workflows` + `Runner` (server-owned identity)

- `list/0`, `get/1`: parse frontmatter + title/description of
  `icm/Workflows/*.md`.
- `Runner.run(workflow_page_path, input_path)` creates a server-owned
  **run record**: `run_id`, Valea session id, workflow path + sha256,
  input path + sha256, `started_at`, `risk_level`/approval from
  frontmatter. It starts a session (`kind: "workflow"`) whose opening
  prompt names the workflow page, the input, and the **exact output
  path** `queue/staging/<run_id>/proposal.json` — which is also the
  session's only write grant. No step orchestration server-side; the
  workflow page is the agent's instruction sheet.
- On turn end the server looks **only at the exact staging path**:
  valid payload → canonical `queue/pending/<run_id>.json` (envelope +
  payload) and the staging dir is cleaned; missing → "finished without
  producing anything for review"; invalid → the unreadable-item state.
  No timestamp-window correlation.

### `Valea.Queue` + `Valea.Audit` (hardened approval)

- The Phase-1 watcher (now under the runtime supervisor) extends to
  `queue/**`. `Valea.Queue` serves list/get; `get_queue_item` returns a
  **revision hash** (sha256 of the file bytes).
- **Approve** (requires `run_id` + revision; stale → `queue_item_changed`):
  1. Atomically claim `pending/<id>.json → processing/<id>.json` (rename;
     already-moved → `queue_item_gone`).
  2. Append a durable **intent** audit record.
  3. Execute idempotently: draft path is deterministic
     (`sources/mail/drafts/<run_id>.md`, frontmatter to/subject/source
     refs + body); an existing draft is treated as already-executed.
  4. Move `processing/ → approved/`; append the completion audit record.
- **Reject** (same revision guard): `pending/ → rejected/`, audited.
- **Crash recovery** on workspace open: items in `processing/` are
  resolved — draft exists → complete to `approved/`; else back to
  `pending/` (audited either way).
- `Valea.Audit`: append-only `logs/audit.jsonl` through one GenServer.
  Entries: `workflow_run_started/finished`, `queue_item_created`,
  `permission_auto_allowed/denied/asked/answered`, `approval_intent`,
  `item_approved/rejected`, `action_executed` — each carrying session id
  and generation, so every trail ends at a transcript file.

### Control-plane authentication (loopback hardening)

Today every socket connection and RPC on the loopback port is accepted.
This phase adds a **per-launch control token**:

- The desktop shell generates a token + readiness nonce and passes both to
  the sidecar (env). The sidecar injects the token into the served SPA
  (production: templated into the index it serves; dev: Vite env var).
- Socket connect and `/rpc/*` require the token; requests without it are
  rejected. A `/health` endpoint echoes the readiness nonce so the shell
  detects port collisions (another process on 4817 won't know the nonce).
- The served SPA gets a real CSP (self-only script/style/connect,
  loopback origins). This closes the ledgered `/rpc` origin/CSRF item.

### RPC surface (typed returns, Phase-2 convention)

`create_session(kind)`, `list_sessions`, `run_workflow(path, input)`,
`harness_doctor`, `list_workflows`, `list_queue_items`,
`get_queue_item(run_id)` (returns revision),
`approve_queue_item(run_id, revision)`, `reject_queue_item(run_id,
revision)`, `list_audit_entries(limit)`. Mutating actions carry the
workspace generation. Errors extend `error_for/1`: `harness_unavailable`,
`session_not_found`, `queue_item_invalid`, `queue_item_gone`,
`queue_item_changed`, `workspace_changed`.

### Channels & live refresh

`agent_session:<id>`: join replays `{items, cursor, busy, status}`;
pushes `event {seq, item}`, `status`, `exit` behind a half-open seq
cursor. Inbound: `prompt`, `cancel`, `permission {request_id, kind}`,
`set_config_option`, `stop`.

`workspace:events` gains `queue_changed` (pushed by the queue watcher) —
the Today and Queue stores refetch on it, defining live Today refresh.

## Frontend

### Chat route

- `ListPane`: sessions (live first, then ended; workflow runs badged);
  "New session" at the bottom.
- Main pane: transcript parts restyled to Paper & ink — user bubbles green
  fill (§9), assistant prose on cards, thought strips, tool-call cards,
  plan bar, permission cards (§6 consequence styling; reject options never
  green), usage meta line, composer with config-option chips and a
  queued-prompt list. **All agent text plain-rendered — no `{@html}`**
  (untrusted).
- Ended sessions render read-only with "Start a follow-up session";
  live continuation only when the adapter advertises resume/load.
- Store: `agent-session.svelte.ts` — id-keyed item map, seq cursor dedup,
  busy falling-edge (vitest-covered).

### Today

- The Priya inquiry card gains **"Prepare a reply"** → run-in-progress
  state (linked to the live transcript) → replaced by a **"Needs your
  approval"** card: REPLY DRAFTED badge, title, summary, source chips,
  and **"Review the draft →"** — approval is **never available from the
  summary alone**. The review view (queue detail) shows the **full
  recipient, subject, and body**, the sources, "Why this? →" (transcript),
  and there — with the full content visible — "Approve — put in my
  drafts" (green fill) and "Don't send this" (outline). Approve/reject
  send the revision hash; a changed item re-renders calmly.
- Cards resolve with a quiet receipt line; `queue_changed` keeps Today
  live.

### Workflows route

Friendly card view over `icm/Workflows/`: name, description, trigger,
source chips, risk badge, §11 numbered step timeline, enabled state
(disabled cards say "not active yet"). "Edit" jumps to the Knowledge page;
raw view one toggle away.

### Audit log route

System nav group → reverse-chron `list_audit_entries` (last 200), §8
dense-receipt rows: icon by type, plain sentence, timestamp, links to
session transcript / queue item.

### Doctor screen

Shown when session creation fails preflight (and from the Chat empty
state): check rows with status, copyable commands, "Check again".

### Workspace switcher

Sidebar: current workspace name (above the status pill) → menu of recents
(`recentWorkspaces`) + "Open another folder…". **Before switching, the
active editor is flushed-or-discarded** (the Phase-2 `onBeforeMutate`
flow; a failed flush blocks the switch with the unsaved-changes message) —
this closes the known hole where a dirty editor could autosave a relative
path into the newly opened workspace. Backend generation checks reject
any stale save that slips through.

## Multi-ICM posture (recorded, mostly deferred)

- **Unrelated ICMs = separate workspaces**, one active at a time — the
  switcher makes it usable.
- **Shared + personal composition = ICM mounts**, a later phase: named
  external ICM roots in workspace config, own top-level Knowledge
  sections, per-mount writability, namespaced references
  (`company:icm/…`), **no override/precedence semantics**.
- **Composition-ready choices made now:** policy contexts carry root
  *lists*; AGENTS.md enumerates ICM roots; queue-item sources stay
  path-based. VISION.md roadmap gains the mounts item.

## Error handling

- Adapter missing / handshake failure / version mismatch / watchdog →
  session `:failed` with a reason; UI routes to the doctor. Subprocess
  exit mid-session → `:exited` with code; transcript intact.
- Prompt-level errors end the turn (never a stuck busy state).
- Invalid queue items: visible-but-unreadable state, raw file one toggle
  away. Revision mismatch → `queue_item_changed`; moved/deleted →
  `queue_item_gone`; stale workspace → `workspace_changed`. All calm copy.
- Channel loss degrades as Phase 1/2 (rejoin replays via cursor; the
  transcript file guarantees nothing is lost).
- Audit write failures are logged loudly server-side but never block the
  action (file moves are the source of truth; audit is the trail).

## Testing

- **Codec:** table-driven frames (handshake incl. clientInfo + version
  validation, resume/load/new preference and load-replay dedup, chunk
  accumulation, tool-call merge, config options + deprecated-mode
  fallback, permission round-trip incl. cancellation outcomes, garbage
  and oversized lines).
- **SessionServer:** integration against a scripted fake adapter (Elixir
  NDJSON script; scenarios: happy path, permission request, mid-turn
  crash, stderr noise, hung handshake → watchdog, process-group cleanup).
- **PermissionPolicy:** unit — deny precedence, symlink escapes, relative/
  `..`/absent paths, chat-has-no-write-root, staging-path-only writes,
  option selection by kind.
- **Settings file:** generated content matches the deny/ask/allow contract;
  regenerated on session start.
- **Frontmatter:** round-trip byte-identity on all seed pages incl. the
  four workflow pages; reattachment under the hash guard; no-frontmatter
  regression.
- **Queue/Audit/Runner:** validate, approve (revision guard, atomic claim,
  idempotent draft, intent-before-execute ordering), reject, stale
  revision, crash recovery from `processing/`, invalid payload; runner
  exact-path correlation; migration idempotence (run twice, byte-stable).
- **Control plane:** tokenless socket/RPC rejected; nonce mismatch
  detected.
- **Frontend (vitest):** session store (cursor dedup, busy falling edge,
  replay merge), queue store, doctor state, switch-flush guard.
- **Acceptance:** (1) doctor catches a missing adapter and a logged-out
  CLI with the right remedies; (2) live chat: ask about an ICM page —
  tool-call card renders, `secrets/` read attempt is denied; (3) Priya
  end-to-end: Run triage → live transcript → pending item → Today card →
  full-draft review → approve → draft file, `approved/` move, complete
  audit chain incl. intent record; (4) an agent write outside its staging
  path raises a permission card (chat: any write); (5) restart →
  transcript replays read-only; (6) workspace switch with a dirty editor
  flushes first, and all agent/queue processes of the old workspace are
  gone; (7) packaged .app runs a real session (erlexec in Burrito) and
  stopping it leaves no orphan processes; (8) `just test` green.

## Out of scope (later phases)

ICM mounts, memory-update suggestion cards, editing drafts before
approval, agent edits to `icm/` (and the save_page concurrent-writer
serialization story), real mail/calendar integration, additional
harnesses (seam only), OS-level
sandboxing of the agent process (recorded hardening option),
scheduled/automatic triggers, frontmatter editing in-app, workflow
authoring UI beyond the ICM editor, multi-account/keychain work.
