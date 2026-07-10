# Agent Prototype Slice — Design (Phase 3)

**Date:** 2026-07-10
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
- **ACP** (Agent Client Protocol, github.com/agentclientprotocol/
  agent-client-protocol, protocol version 1) is the adapter boundary between
  Valea and agent harnesses. Claude Code connects through the
  **`@agentclientprotocol/claude-agent-acp`** adapter (binary
  `claude-agent-acp`; the `@zed-industries/claude-code-acp` package legend
  uses is deprecated in favor of this rename).
- **The ICM paper** (Van Clief & McDermott, arxiv.org/html/2603.16021v2)
  drives three structural decisions here: Layer 0/1 files (`CLAUDE.md`,
  `AGENTS.md`) orient the agent; **Layer 2 stage contracts move into the ICM**
  as markdown workflow pages; Layer 4 working artifacts (`queue/`, `logs/`)
  stay machine-managed behind review gates.
- **Legend** (read-only donor) contributes its proven ACP core: a pure
  JSON-RPC codec, a session GenServer owning the subprocess, and a harness
  seam of exactly one callback per agent.

Product decisions made in brainstorming:
- **Session cwd = workspace root.** The agent sees `icm/`, `sources/`,
  `prompts/` and writes only `queue/pending/`.
- **Chat + workflow run** are both in scope: the Chat nav item becomes a real
  conversation surface; "Prepare a reply" on the seeded Priya inquiry drives
  the same session machinery through a workflow.
- **Permissions: policy + cards.** Reads inside the workspace and writes into
  `queue/pending/` auto-allow (audited); everything else surfaces as a UI
  permission card.
- **Claude Code only.** No mock harness; the seam stays (adding an agent is a
  ~10-line module); tests stub at the protocol layer with a scripted fake
  adapter.
- **Transcripts are workspace files.** `logs/sessions/<id>.jsonl`, appended
  as items arrive — canonical record, audit artifact, and replay source.
  Live continuation after restart is capability-gated on `loadSession`
  (the adapter may not support it; degrade to read-only history + follow-up
  session).
- **Auth is delegated.** Valea stores no credentials; the adapter uses the
  user's own Claude login. A **guided doctor flow** handles missing/broken
  setup.
- **Approach A: vendor legend's ACP core** (pure codec near-verbatim with
  origin headers, slimmer single-transport session server, chat UI parts
  restyled to Paper & ink). Rejected: bespoke minimal client (re-derives
  solved landmines), headless `claude -p` (no permissions, no cancellation,
  abandons the harness boundary).
- **Workflows become ICM pages**: `icm/Workflows/*.md`, YAML frontmatter for
  the machine, markdown body for humans and agents. Rejected: keeping
  `workflows/*.yaml` (Layer 2 outside the tree, uneditable in-app), YAML
  files inside `icm/` (raw-only pages).
- **Multi-ICM**: unrelated ICMs = separate workspaces (already the
  architecture; this phase adds a sidebar switcher). Shared + personal
  composition = **ICM mounts, a later phase** — recorded in VISION.md;
  this phase only keeps the door open (see §Composition-ready choices).

## Workspace files

### AGENTS.md / CLAUDE.md (paper Layer 0/1)

Seeded at the workspace root by the template. **`AGENTS.md` is canonical**;
`CLAUDE.md` contains only `@AGENTS.md` so Claude Code imports the same truth.
Content, in plain language:

1. **Who you work for & what this folder is** — one paragraph, then the
   workspace map: `icm/` is reference memory (read what a job's `sources:`
   name — do not slurp the tree); `icm/Workflows/` are your job contracts;
   `sources/` is read-only input; `queue/pending/` is the only place you
   create work product; `logs/` and `secrets/` are off-limits. Written as an
   enumeration of ICM roots (today: one) so mounts can extend it later.
2. **Hard rules** — never send anything; never delete; never edit `icm/`
   pages (memory-update suggestions are a later feature); one queue item per
   workflow run; when unsure, stop and say so in your reply rather than
   guessing.
3. **The queue item contract** — the exact JSON schema (below), with one
   worked example.

### Queue item schema (`queue_item/v1`)

Written by the agent to `queue/pending/<UTC-timestamp>-<slug>.json`:

```json
{
  "schema": "queue_item/v1",
  "workflow": "icm/Workflows/New Inquiry Triage.md",
  "created_at": "2026-07-10T09:14:00Z",
  "kind": "email_draft",
  "title": "Reply to Priya Nair — coaching inquiry",
  "summary": "Good-fit inquiry. Drafted a warm reply proposing a discovery call.",
  "sources": [
    "sources/mail/normalized/priya-nair-inquiry.json",
    "icm/Offers/Founder Coaching Package.md",
    "icm/Tone & Voice/Email Tone Guide.md"
  ],
  "risk_level": "medium",
  "proposed_action": {
    "type": "create_email_draft",
    "to": "priya@example.com",
    "subject": "Re: Question about leadership coaching",
    "body_markdown": "…"
  },
  "reasoning": "Classified good-fit because …"
}
```

The backend validates on pickup. An invalid item surfaces as a calm "the
assistant produced something I couldn't read" state (with the raw file one
toggle away), never a crash. MVP action vocabulary: `create_email_draft`
only.

### Workflow pages (paper Layer 2, now in the ICM)

The template's four `workflows/*.yaml` convert to `icm/Workflows/*.md` and
the root `workflows/` folder disappears. Format — YAML frontmatter (machine)
+ markdown body (human & agent):

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

## Steps

1. Summarize the incoming inquiry.
2. Classify: good-fit, unclear, not fit, or spam.
3. Draft a warm reply using the tone guide and the relevant offer.
4. Write one pending queue item per the AGENTS.md contract. Do not send.
```

VISION.md principle 3 is amended: workflows are "inspectable markdown
contracts with a YAML header."

### harnesses.yaml

Rewritten: mock removed. `default: claude_code`;
`claude_code: { kind: acp, command: claude-agent-acp }` (command
overridable per workspace).

## Frontmatter passthrough (ICM/editor change)

`Valea.ICM` learns to split an optional leading `---\n…\n---\n` block:

- `icm_page` returns a new `frontmatter` field (parsed map, null when
  absent) alongside `content`/`prosemirror`; the ProseMirror conversion
  sees **only the body**.
- `save_page` re-reads the file under the existing hash guard, splits the
  current frontmatter, serializes the body, and writes
  `frontmatter <> body` — the frontmatter block is reattached
  **byte-identical**. The determinism contract extends: frontmatter never
  churns; a page without frontmatter behaves exactly as today.
- Frontmatter is **not editable in-app** this phase (raw file or external
  editor); `PageMeta` displays the parsed fields read-only. The token-cost
  estimate counts the whole file (the agent reads the whole file).
- The Phase-2 round-trip suite gains frontmatter fixtures (all four workflow
  pages round-trip byte-identically).

`Valea.ICM.References` scans `icm/Workflows/*.md` instead of
`workflows/*.yaml` — same literal string scan, wildcard pairs included.
Renames that rewrite a workflow page compose with the Phase-2
external-change machinery if that page is open in the editor.

## Backend architecture

New deps: `erlexec` (subprocess spawning), `yaml_elixir` (frontmatter).
**Flagged risk, verified first:** erlexec ships a C port binary — its
survival inside the Burrito-packaged sidecar must be proven before anything
builds on it (plan Task 1 territory).

### Harness seam

- `Valea.Agents.CommandSpec` — `%{cmd, args, env, io: :pipes}`.
- `Valea.Harness` behaviour — `definition/0` (id, name) +
  `acp_command(opts)`.
- `Valea.Harnesses.ClaudeCode` — the only implementation: resolves the
  command from the workspace's `config/harnesses.yaml` (default
  `claude-agent-acp`), merges env. ~10 lines of substance.

### `Valea.Acp.Connection` (vendored pure codec)

From `legend/backend/lib/legend/core/acp/connection.ex` with an origin
header. Pure functions over a struct: `{state, render_items, reply_frames,
effects}`. Carries legend's protocol lessons verbatim:

- NDJSON framing (newline-delimited JSON-RPC, no LSP headers); 1 MiB
  incomplete-line cap; undecodable lines logged and dropped.
- `initialize` (protocolVersion 1, empty client capabilities) →
  **capability-gated** `session/load` (only if `agentCapabilities.
  loadSession` AND resuming) else `session/new` with `{cwd, mcpServers: []}`.
- Update reducer: message/thought chunk accumulation per turn, tool-call
  merge by id (status, diff extraction, output capped 64 KiB tail-kept),
  plan, available commands, mode/model config items.
- `session/request_permission` → permission render item + pending-id map;
  answers reply `{outcome: {outcome: "selected", optionId}}`; unknown
  agent→client requests get `-32601` immediately so the agent never hangs.
- `session/prompt` per turn; response `stopReason` ends the turn (an error
  response still ends it); `session/cancel` notification clears pending
  permissions.

### `Valea.Agents.SessionServer`

One GenServer per session (`restart: :temporary`, DynamicSupervisor +
Registry by session id). Responsibilities:

- Spawn the adapter via erlexec with `io: :pipes`, `cd:` workspace root,
  inherited user env. stderr is a separate stream — logged, never decoded.
- 30 s handshake watchdog → `:failed` with a reason the doctor flow can use.
- Feed stdout bytes to the codec; write reply frames; execute effects.
- **Append every timeline item to `logs/sessions/<id>.jsonl` as it
  arrives** (line 1 = metadata: `{schema: "session/v1", id, kind:
  "chat"|"workflow", title, workflow, harness, started_at}`; then
  `{seq, item}` lines). The file is canonical; a crash loses nothing.
- Broadcast `{seq, item}` / status / exit on PubSub topic
  `agent_session:<id>`.
- Run permission requests through the policy before they ever reach the UI.
- One-turn-at-a-time prompt queue (legend's `turn_in_flight?` gate).
- On exit the server stays up (transcript viewable) until the app closes;
  after restart the file alone serves replay.

Session ids are backend-generated (`<UTC-timestamp>-<random-suffix>`).

### `Valea.Agents.PermissionPolicy`

Pure: `(permission_params, allowed_read_roots, allowed_write_roots) ->
{:allow, option_id} | :ask`. Today `allowed_read_roots =
[workspace_root]`, `allowed_write_roots = [queue/pending]` — **lists, so
ICM mounts can extend them later.** Rules:

- Extract candidate paths from the tool call's `rawInput`; normalize against
  the workspace root (the containment chokepoint's logic reused).
- Read-kind tool call, all paths inside a read root → allow.
- Edit/write-kind, all target paths inside a write root → allow.
- Execute/terminal kinds, missing/ambiguous paths, anything outside →
  `:ask`. Conservative by construction.
- Every decision (auto-allow and ask alike) is audited.
- `:allow` selects the adapter's allow-once option (never "always allow").

### `Valea.Agents.Doctor`

RPC returning check results (status per check: ok / failed / unknown, plus
the copyable remedy command):

1. Adapter binary resolves on PATH (`claude-agent-acp` or configured
   command) — remedy `npm install -g @agentclientprotocol/claude-agent-acp`.
2. Adapter answers `--version` within a short timeout.
3. Claude auth: best-effort probe of the `claude` CLI's auth state; result
   may honestly be "unknown" — remedy `claude /login` in a terminal.

### `Valea.Workflows` + `Runner`

- `list/0`, `get/1`: parse frontmatter of `icm/Workflows/*.md` (enabled,
  trigger, sources, risk, approval) + title/description from the body.
- `Runner.run(workflow_page_path, input_path)`: starts a session with
  `kind: "workflow"`, opening prompt (composed server-side): read the
  workflow page, execute its steps against the named input, follow the
  AGENTS.md queue contract, stop when the item is written. **No step
  orchestration on our side** — the workflow page is the agent's
  instruction sheet.
- Run completion = turn ended AND a valid pending item appeared
  (watcher-confirmed, correlated by the item's `workflow` field and
  creation window). Turn ended without an item → "finished without
  producing anything for review" state.

### `Valea.Queue` + `Valea.Audit`

- The Phase-1 file watcher extends to `queue/**`. `Valea.Queue` validates
  `queue_item/v1`, serves list/get, and executes decisions:
  - **Approve (backend, deterministic — never the agent):** write
    `sources/mail/drafts/<id>.md` (frontmatter: to, subject, source refs;
    body below), move the JSON `pending/ → approved/`, audit.
  - **Reject:** move `pending/ → rejected/`, audit.
- `Valea.Audit`: append-only `logs/audit.jsonl` through one GenServer
  (serialized writes). Entries: `workflow_run_started/finished`,
  `queue_item_created`, `permission_auto_allowed/asked/answered`,
  `item_approved/rejected`, `action_executed` — each carrying the session
  id, so every trail ends at a transcript file.

### RPC surface (typed returns, Phase-2 convention)

On new Ash resources `Valea.Api.Agents`, `Valea.Api.Queue`: 
`create_session(kind)`, `list_sessions` (scan `logs/sessions/` first
lines + live registry), `run_workflow(path, input)`, `harness_doctor`,
`list_workflows`, `list_queue_items`, `get_queue_item`,
`approve_queue_item(id)`, `reject_queue_item(id)`. Errors extend the
central `error_for/1` vocabulary: `harness_unavailable`,
`session_not_found`, `queue_item_invalid`, `queue_item_gone`.

### Channel

`agent_session:<id>` Phoenix channel. Join replays
`{items, cursor, busy, status}` from the server (or the file, for ended
sessions); pushes `event {seq, item}`, `status`, `exit` gated by a
half-open seq cursor. Inbound: `prompt`, `cancel`, `permission
{request_id, option_id}`, `set_mode`, `set_model`, `stop`.

## Frontend

### Chat route (real, at last)

- `ListPane`: sessions (live first, then ended, workflow runs badged with
  the workflow name); "New session" primary-quiet at the bottom.
- Main pane: vendored-and-restyled transcript parts — user bubbles green
  fill (§9), assistant prose on cards, thought strips, tool-call cards
  (kind, title, status glyph, diff, output), plan bar, permission cards
  (§6 consequence styling: reject options never green), composer with
  mode/model chips and a queued-prompt list. **All agent text
  plain-rendered — no `{@html}`, no markdown injection** (untrusted).
- Ended sessions render the same transcript read-only with a "Start a
  follow-up session" affordance (live continuation only if the adapter
  advertises `loadSession`).
- Store: `agent-session.svelte.ts` — id-keyed item map, seq cursor dedup,
  busy falling-edge (legend's pattern, vitest-covered).

### Today

- The Priya inquiry card gains **"Prepare a reply"** → run-in-progress
  state (linked to the live transcript) → replaced by a **"Needs your
  approval"** card: REPLY DRAFTED badge, title, summary, source chips
  (dot colors per source type), "Approve — put in my drafts" (green
  fill), "Don't send this" (outline), "Why this? →" opens the session
  transcript.
- Approving/rejecting hits the RPC; the card resolves with a quiet receipt
  line.

### Workflows route

Friendly card view over `icm/Workflows/`: name, description, trigger,
source chips, risk badge, §11 numbered step timeline (final approval step
is the only green circle), enabled state. "Edit" jumps to the Knowledge
page; raw view one toggle away. Manual-trigger workflows get a quiet "Run"
affordance where their trigger input exists (this phase: only the inquiry
triage, from Today).

### Audit log route

System nav group → reverse-chron list of `logs/audit.jsonl` entries (last
200), each row a receipt (§8 dense-row style): icon by entry type, plain
sentence, timestamp, link to session transcript / queue item where
applicable.

### Doctor screen

Shown when session creation fails preflight (and reachable from the Chat
empty state): three check rows with status, copyable commands, "Check
again". Paper-calm; no red walls.

### Workspace switcher

Sidebar: the current workspace name (bottom, above the status pill)
becomes a menu — recent workspaces (from existing `recentWorkspaces`
RPC), "Open another folder…" (same path input the onboarding uses).
Switching drives the existing `openWorkspace` machinery; all stores
already reset on the workspace-change event.

## Multi-ICM posture (recorded, mostly deferred)

- **Unrelated ICMs = separate workspaces**, one active at a time — already
  the architecture; the switcher makes it usable.
- **Shared + personal composition = ICM mounts**, a later phase: workspace
  config lists named external ICM roots; each appears as its own
  top-level Knowledge section with per-mount writability; references are
  namespaced (`company:icm/…`); no override/precedence semantics —
  distinct pages read side-by-side (the interpretable answer).
- **Composition-ready choices made now:** PermissionPolicy takes root
  *lists*; AGENTS.md enumerates ICM roots; queue-item sources stay
  path-based. VISION.md roadmap gains the mounts item.

## Error handling

- Adapter missing / handshake failure / watchdog → session `:failed` with
  a reason; the UI routes to the doctor. Subprocess exit mid-session →
  `:exited` with code; transcript intact; calm status line.
- Prompt-level errors end the turn (never a stuck busy state).
- Invalid queue items: visible-but-unreadable state, raw file one toggle
  away. Approve/reject on a moved/deleted item → `queue_item_gone`, calm
  copy.
- Channel loss degrades as Phase 1/2 (rejoin replays via cursor; the
  transcript file guarantees nothing is lost).
- Audit write failures are logged loudly server-side but never block the
  action (the queue file move is the source of truth; audit is the trail).

## Testing

- **Codec:** table-driven frame tests (handshake, capability degradation,
  chunk accumulation, tool-call merge, permission round-trip, garbage
  lines, oversized lines).
- **SessionServer:** integration against a **scripted fake adapter** (small
  Elixir NDJSON script; scenarios: happy path, permission request, mid-turn
  crash, stderr noise, hung handshake → watchdog).
- **PermissionPolicy:** unit — path extraction edge cases (relative, `..`,
  absent paths), kind classification, root lists.
- **Frontmatter:** round-trip byte-identity on all seed pages incl. the four
  workflow pages; save-reattachment under the hash guard; page-without-
  frontmatter regression.
- **Queue/Audit/Runner:** file-state tests in tmp workspaces (validate,
  approve → draft + moves + audit ordering, reject, invalid item);
  runner prompt composition; completion correlation.
- **Frontend (vitest):** session store (cursor dedup, busy falling edge,
  replay merge), queue store, doctor state.
- **Acceptance:** (1) doctor catches a missing adapter with the right
  remedy; (2) live chat: ask about an ICM page, agent reads it, answer
  renders with tool-call card; (3) Priya end-to-end: Run triage → live
  transcript → pending item → approval card on Today → approve → draft
  file exists, item in `approved/`, complete audit chain; (4) an agent
  write outside `queue/pending/` raises a permission card; (5) restart the
  app → session transcript replays read-only; (6) workspace switcher
  swaps ICMs cleanly; (7) `just test` green.

## Out of scope (later phases)

ICM mounts (shared+personal composition), memory-update suggestion cards,
editing drafts before approval, agent edits to `icm/` (and with it the
save_page concurrent-writer serialization story), real mail/calendar
integration, additional harnesses (seam only), MCP server injection into
sessions, scheduled/automatic triggers, session continuation via
`session/load` unless the adapter advertises it, frontmatter editing
in-app, workflow authoring UI beyond the ICM editor.
