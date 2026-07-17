# Valea — Product Vision

**Working name:** valea · **By:** wir drei digital · **Written:** 2026-07-09

## North star

The only local-first app a solopreneur needs to understand the day, review
prepared work, manage open loops, and teach their AI assistant how their
business works.

## What Valea is

Valea is a **local-first agentic operating system for solopreneurs**. It
combines a basic email client, calendar, chat assistant, task management, and
business memory into a single desktop app — with an AI assistant that prepares
admin work transparently, explains its reasoning, and waits for human approval
before taking any consequential action.

**Core promise:** one local-first app that knows your business context, watches
your daily admin streams, prepares the boring work, explains every suggestion,
and asks before acting.

**First target avatar:** an independent coach whose daily business runs on
client inquiries, scheduling, session preparation, follow-ups, invoices, and a
weekly admin review. (Seed persona: Mara Lindt, Mara Lindt Coaching.)

## The five principles

1. **Local-first ownership, with clear boundaries.** The user owns each ICM
   folder: business memory, workflows, context routing, and methodology remain
   visible, portable, versionable files that work without Valea. Valea owns a
   separate private local **workspace profile** for connected accounts,
   normalized sources, approvals, audit history, session transcripts, and its
   SQLite cache. Nothing canonical is cloud-hosted by default; the user can
   inspect, back up, export, or walk away with both their ICM folders and the
   local operational profile.

2. **ICM at the core — as composable capability modules.** ICM
   (Interpretable Context Methodology) is the user's human-readable business
   memory — a file/folder structure of Markdown pages (offers, pricing,
   clients, tone of voice, policies, templates, decisions) reflected
   directly in the app navigation. **The AI never "just knows things."** It
   uses visible, editable memory, and every suggestion shows which pages and
   sources it used. The methodology is formalized in *"Interpretable Context
   Methodology: Folder Structure as Agent Architecture"* (Van Clief &
   McDermott, arxiv.org/html/2603.16021v2). A workspace profile mounts one or
   more ICMs **by reference**, wherever the user already keeps them. Each ICM
   is a uniform, portable context project: its own Layer 0/1 identity and
   routing (`CLAUDE.md`, `AGENTS.md`, `CONTEXT.md`), Layer 2+ job knowledge
   as freeform prose the agent interprets — not a Valea-owned folder
   convention or file format; the user and their agent decide how their own
   ICM is organized — Layer 3 reference knowledge, reusable prompt
   fragments, and optional scripts. Every agent session belongs to exactly
   one **primary
   ICM** and runs with that ICM as its coding-harness cwd. Other mounted ICMs
   are available projects, not a global context bundle; they join only when
   the primary ICM explicitly declares them as related context. The workspace
   supplies Layer 4 working artifacts — exact source inputs and proposal
   outputs — without becoming agent identity or routing. The app is the
   convenience and trust layer; every ICM stays usable by a bare coding
   harness with no Valea present.

3. **The agent interprets your prose; Valea doesn't own a workflow format.**
   Valea stopped trying to structure how a business documents its own
   process — there is no reserved folder, YAML-header contract, or workflow
   registry/card UI. A "workflow" is just a markdown document the user
   writes however makes sense to them; the agent reads and follows it
   directly when a session names it as context, the same way a person would
   hand a colleague a runbook. Routing between documents is itself prose —
   `CONTEXT.md` tables at every level saying where to look for what.
   Nothing is hidden — Valea must not become a new black box ("Open the
   hood"), and the human stays in the loop through the live permission
   ask-gate on every consequential step, not a structured approval schema.

4. **AI prepares; human approves.** The assistant summarizes, classifies,
   drafts, prepares briefs, suggests tasks, and proposes memory updates. It
   does **not**, by default: send emails, cancel or move appointments, change
   invoices, delete data, silently update important memory, or perform
   irreversible external actions. Everything consequential goes through the
   live permission ask-gate — the human reviews the exact diff in the
   moment, before it happens, not a staged queue reviewed later — and every
   step lands in the audit log.

5. **Pluggable AI harnesses.** Valea does not build a custom agent runtime. It
   integrates existing agent harnesses (Claude Code first, then OpenCode,
   Codex, Hermes, Pi, direct API, local models) behind an adapter boundary.
   **The app owns workspace profiles, ICM mount relationships, session
   creation and permission asks, audit logs, and UI. The harness only
   executes tasks and returns structured results.** This is a **file-first
   integration** by product principle, not phase limitation: every resource
   the agent consumes or produces — ICM pages, incoming mail, proposals,
   drafts — is a plain file. A harness starts inside the primary ICM and
   receives only explicitly related ICM roots plus exact workspace inputs and
   outputs. There are no custom tools and no custom MCP servers; coding
   harnesses are used at what they already do best (read/edit files, run
   commands), and future integrations (real mail, calendar) are sync-to-files
   engines, never new tool surfaces the agent must learn.

## Where the value lives

The product value is **not** owning the model or the harness. The value is
owning the **context** (ICM), the **workflows**, the **approvals**, the
**audit trail**, and the **user experience** — the trust layer between a
person's business and whatever AI executes the work. Harnesses will keep
changing; the user's business memory and their trust in the system compound.

## How it should feel

Calm, trustworthy, warm, focused, local, transparent. Design language: *"paper
& ink, with a green pen for approval"* — the palette does the safety talking
(**green acts, amber suggests, terracotta warns**; see
[DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)).

Copy patterns we use: "Prepared for you", "Needs your approval", "Used these
sources", "Nothing has been sent or changed without your approval", "Open the
hood", "Why this?". Never: hype language, glowing AI effects, "automated for
you" without explanation, vanity-metric dashboards. Plain language first;
technical detail is one toggle away, never the default.

## First run

Onboarding is the principles made tangible: *"Welcome. Your knowledge stays in
folders you own."* A fresh instance offers two paths. **Start fresh** creates
a new portable ICM in a visible user-owned location, creates Valea's private
workspace profile automatically, mounts the ICM by reference, and opens its
guided first session. **Use an existing ICM** selects a folder the user already
has; Valea validates and mounts it in place, again creating the private
workspace profile automatically. The user names the business/profile but is
never asked to choose or understand a workspace storage folder. Additional
workspaces remain useful for different account setups, ICM sets, and
audit histories, and are created or selected from the workspace switcher. The
trust bar states the deal plainly: runs on this machine, keys stay in the
system keychain, ICMs remain yours, and nothing is copied or moved behind your
back.

## The daily loop we're building toward

*(as of Spec D: unattended overnight work is future scope — a deterministic
script contract, not an agent pipeline, per the "unattended work is
deterministic scripts, not agent pipelines" design principle. Today's
mechanism for step 1 below is a human- or script-triggered agent session
started with a document + input, per "The agent interprets your prose"
above — not a Valea-scheduled "workflow run".)*

1. Overnight/morning: the admin streams (the mirrored inboxes, upcoming
   sessions) get worked — today by a session someone starts pointed at the
   right document and input, eventually by a scheduled deterministic step —
   producing drafts, briefs, and suggestions, each with sources and
   reasoning.
2. Morning cockpit: "Good morning, Mara. Two sessions today, one new inquiry,
   one overdue invoice. I prepared three things overnight — nothing has been
   sent or changed without your approval."
3. The user reviews, edits, approves, rejects, or snoozes. High-risk items
   (anything that leaves the house) are visually unmistakable and never one
   click from disaster.
4. Approved actions execute (MVP: local drafts only); the audit log records
   the full chain; open loops and memory stay current.
5. Over time the user *teaches* the assistant — tone, policies, pricing,
   decisions — by editing memory pages and approving memory-update
   suggestions. The assistant gets better because the context gets better.

## MVP non-goals

No full email client replacement (rules engines, full search), no email
sending (drafts + user-pushed Drafts-folder handoff only), no CalDAV writes, no browser automation, no
bookkeeping integration, no visual workflow builder, no multi-agent
orchestration UI, no cloud sync, no mobile app, no team collaboration, no
plugin marketplace, no external booking links.

## Technical posture (summary)

Tauri desktop app; SvelteKit static SPA frontend; Elixir/Phoenix/Ash backend
bundled as a sidecar binary. Valea workspace profiles live in the private
local app directory and own integrations, sources, audit, transcripts, and
SQLite cache. ICMs live separately in user-owned folders and are mounted
by reference; every session uses one ICM as its harness cwd. Full decisions
per feature live in `docs/superpowers/specs/`; `docs/ARCHITECTURE.md` records
the currently implemented system, while approved future restructurings remain
clearly marked in their design specs until implemented.

## Roadmap shape (reordered 2026-07-10 — prototype first)

1. **Foundation** — app shell, workspace creation/seeding, Today cockpit
   (seeded), ICM tree in nav. *(shipped; spec:
   2026-07-09-valea-foundation-design.md)*
2. **ICM editor** — Notion-like tiptap editing of memory pages, tree CRUD,
   deterministic markdown round-trip. *(spec:
   2026-07-10-icm-editor-design.md)*
3. **Agent prototype slice** — the full AI-prepares-human-approves loop with
   zero external integrations: real ACP agent sessions (Claude Code) running
   in the workspace, chat UI, workflow execution on the seeded mock email,
   hardened approval queue + audit log, prepared card on Today. Adopts the
   ICM paper's Layer 0/1 as combined root `AGENTS.md`/`CLAUDE.md` files, and
   hosts Layer 2 stage contracts as `icm/Workflows/*.md` inside the
   reference tree itself (later superseded by ICM mounts, item 7). After this phase Valea is a demo-able product with
   no accounts connected. *(shipped, pending merge; spec:
   2026-07-10-agent-slice-design.md — its workflow-execution/approval-queue
   half is superseded by item 10 below; the agent runtime, chat UI, trust
   model, and audit log it shipped remain live.)*
4. **Mail** — per-account maildir mirrors under `sources/mail/<slug>/` with
   derived markdown views, two-way sync through declared, verified ops
   (moves + flags; never expunge), and agent-proposed drafts the USER
   pushes to the mailbox's Drafts folder — no SMTP anywhere. The agent's
   surface stays files: views to read, `ops/pending/` + `drafts/` to
   write. *(shipped; specs: 2026-07-11-mail-design.md, superseded by
   2026-07-17-mail-maildir-design.md)*
5. **Calendar** — a sync-to-files engine that reads CalDAV / imports ICS
   into `sources/calendar/`, today + week views. Same file-first posture as
   Mail.
6. **Workflows & agents, full depth** — registry UI, context bundles,
   additional harnesses beyond Claude Code, everything the prototype slice
   deferred.
7. **ICM projects & workspace profiles** — replaced the interim embedded/global
   mount composition with the final boundary: private Valea workspace profiles
   mount user-owned ICM folders by reference; every session selects one
   primary ICM and runs with that ICM as cwd; related ICMs are explicit rather
   than globally routed; the main sidebar groups each mounted ICM with its five
   recent sessions; onboarding starts fresh or from an existing ICM without
   asking for a workspace path. Workspaces remain switchable account and
   operational boundaries. *(Shipped; spec: [Workspace Profiles, Mounted ICM
   Projects & ICM-Scoped Sessions](superpowers/specs/2026-07-13-icm-project-workspaces-design.md).
   Supersedes and replaces Plan A/A2 outright — Phase 11's clean-cut removed
   every embedded-mount, `MOUNTS.md`, and workspace-migration code path those
   designs shipped; nothing from them survives at runtime. See
   [ARCHITECTURE.md](ARCHITECTURE.md#icm-project-workspaces) for the as-built
   record.)*
8. **Methodology depth** — closes the teaching loop (principle 2/4, daily-loop
   step 5): a server-derived risk tier makes a proposed edit's stakes
   explicit (a mount's `Workflows/*.md`/`AGENTS.md`/`CLAUDE.md`/`icm.yaml`
   are `high` — they change future agent behavior — everything else in a
   mount is `medium`); the chat ask-gate dialog now renders a line diff and
   that risk banner in the moment; workflow runs and a reflection workflow
   ("Distill recent decisions", mining a server-compiled 30-day digest of
   decided queue items) stage memory-update PROPOSAL PAIRS instead of editing
   directly, applied by a hash-guarded queue executor with conflict
   hand-back and content-hash crash recovery; rejections optionally carry a
   one-line reason, visible in the decided history. *(Spec B — shipped,
   pending merge on `feat/methodology-depth`; spec:
   2026-07-12-methodology-depth-design.md. **Its queue-backed
   memory-update-proposal machinery is superseded by item 10 below** — the
   risk tier and the chat ask-gate line-diff dialog survive, updated for a
   depth-aware tier rule instead of the `Workflows/*.md`-prefix rule
   described here.)*
9. **Knowledge & editor depth** — makes Knowledge a genuinely daily-usable
   surface, entirely as standard GFM markdown on disk: a scan-backed
   literal search (per-mount concurrent scan under a shared budget, top 20
   results) whose RPC contract is deliberately implementation-agnostic so
   FTS5 can replace the scan internals later without a contract break;
   AST-confirmed backlinks (a real Link/Image node, never a prose mention
   or code-fence lookalike); a byte-surgical rename link-rewrite that
   keeps the editor's determinism contract intact (two documented,
   non-corrupting limitations); page templates (a `Templates/` folder per
   mount, `{{title}}`/`{{date}}` substitution); contained image
   upload/serve endpoints (`Assets/<slug>-<hash8>.<ext>`, the serve route
   deliberately token-exempt since an `<img>` tag can't send headers and
   the listener is loopback-only); and, on the frontend, a `[[`/`@`
   page-link picker inserting standard link marks, a Cmd+K search palette
   with an MRU, link-click navigation with dangling-link decoration and
   create-on-click, a backlinks panel, and page-aware rename/delete impact
   dialogs. *(Spec C — shipped, pending merge on
   `worktree-knowledge-depth`; spec:
   2026-07-12-knowledge-depth-design.md. Its page-templates discovery was
   made recursive by item 10 below — any folder named `templates/`, not
   only a single top-level `Templates/` per mount.)*
10. **Agent-native ICMs** — Valea stops interpreting ICM structure and
    becomes cockpit + guardrails + building blocks; the agent is the
    interpreter of an ICM's prose. Deletes the workflow subsystem outright
    (registry, staged-approval queue, memory-update proposal pairs, the
    reflection digest workflow); replaces "run" with one kind-agnostic
    session-with-context primitive (`context_doc` to read-and-follow,
    `input` as an exact read grant, fail-closed at session start); makes
    Today a file (`today.json`) the agent maintains directly instead of
    Valea-seeded content; adds adopt-a-folder mounting (one consent step
    mints a minimal identity file into a manifest-less folder instead of
    requiring a pre-existing `icm.yaml`); makes the risk tier and template
    discovery depth-aware instead of top-level-only; adds an ICM-internal
    secrets deny tier (`secrets/`, `.env*`, `*.pem`/`*.key`,
    `*credentials*` — denied, never asked); and re-scopes the starter seed
    to a 3-layer prose pattern (identity + map + router table + one example
    domain folder) with no reserved `Workflows/`/`Templates/`/`Decisions/`
    convention. *(Spec D — shipped; spec:
    [Agent-native ICMs design](superpowers/specs/2026-07-16-agent-native-icms-design.md).
    See [ARCHITECTURE.md](ARCHITECTURE.md) for the as-built record and the
    full list of what this deleted.)*

The MVP is complete when the core acceptance scenario runs end-to-end: open
app → move Priya's inquiry to AI/Review → start a session with an inquiry
workflow document and the message as input → review the prepared draft
with sources via the ask-gate diff → approve → local draft created, full
chain in the audit log — and "Open the hood" shows the plain files behind
all of it.
