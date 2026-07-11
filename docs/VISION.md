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

1. **Local-first ownership.** The user owns the workspace folder. Business
   memory, workflows, queue items, and audit logs live locally as readable
   files. SQLite is a cache/index layer; the canonical data is file-backed. The
   user can inspect, back up, export, version, or hand off the workspace at any
   time — without us.

2. **ICM at the core.** ICM (Interpretable Context Methodology) is the user's
   human-readable business memory — a file/folder structure of Markdown pages
   (offers, pricing, clients, tone of voice, policies, templates, decisions)
   reflected directly in the app navigation. **The AI never "just knows
   things."** It uses visible, editable memory, and every suggestion shows
   which pages and sources it used. The methodology is formalized in
   *"Interpretable Context Methodology: Folder Structure as Agent
   Architecture"* (Van Clief & McDermott, arxiv.org/html/2603.16021v2):
   Valea's root `AGENTS.md`/`CLAUDE.md` are Layer 0/1 (root instructions +
   routing, deliberately combined into one file at this workspace size),
   `icm/Workflows/*.md` are Layer 2 stage contracts (hosted inside the
   reference tree itself — a documented Valea adaptation, not a separate
   `workflows/` folder), the rest of `icm/` is Layer 3 (stable reference
   material), and `queue/`/`sources/` are Layer 4 working artifacts behind
   review gates.

3. **Transparent workflows.** Workflows are inspectable markdown contracts
   with a YAML header: trigger, sources, steps, outputs, approval
   requirements, risk level, audit behavior. Every workflow is readable as a
   friendly card in the UI *or* as the raw file. Nothing is hidden — Valea
   must not become a new black box ("Open the hood").

4. **AI prepares; human approves.** The assistant summarizes, classifies,
   drafts, prepares briefs, suggests tasks, and proposes memory updates. It
   does **not**, by default: send emails, cancel or move appointments, change
   invoices, delete data, silently update important memory, or perform
   irreversible external actions. Everything consequential goes through the
   approval queue, and every step lands in the audit log.

5. **Pluggable AI harnesses.** Valea does not build a custom agent runtime. It
   integrates existing agent harnesses (Claude Code first, then OpenCode,
   Codex, Hermes, Pi, direct API, local models) behind an adapter boundary.
   **The app owns the workspace, context bundles, workflow specs, approval
   queue, audit log, and UI. The harness only executes tasks and returns
   structured results.** This is a **file-first integration** by product
   principle, not phase limitation: every resource the agent consumes or
   produces — memory pages, incoming mail, proposals, drafts — is a plain
   file in the workspace, and the file tree **is** the agent's API. There are
   no custom tools and no custom MCP servers; coding harnesses are used at
   what they already do best (read/edit files, run commands), and future
   integrations (real mail, calendar) are sync-to-files engines, never new
   tool surfaces the agent must learn.

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

Onboarding is the principles made tangible: *"Welcome. Your business runs on a
folder you own."* A fresh instance offers two paths — **set it up in
conversation** (about 15 minutes of talking; the assistant builds the workspace
as you go, and you approve each page it writes; nothing connects without
asking) or **open an existing workspace** (from a consultant handoff, a backup,
or another machine — everything picks up where it left off). The trust bar
states the deal plainly: runs on this machine, keys stay in the system
keychain, export or walk away with the folder anytime.

## The daily loop we're building toward

1. Overnight/morning: workflows watch the admin streams (mail moved to
   AI/Review, upcoming sessions) and prepare drafts, briefs, and suggestions —
   each with sources and reasoning.
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

No full email client replacement (rules engines, full search, multi-account),
no email sending (drafts only), no CalDAV writes, no browser automation, no
bookkeeping integration, no visual workflow builder, no multi-agent
orchestration UI, no cloud sync, no mobile app, no team collaboration, no
plugin marketplace, no external booking links.

## Technical posture (summary)

Tauri desktop app; SvelteKit static SPA frontend; Elixir/Phoenix/Ash backend
bundled as a sidecar binary; SQLite inside the user's workspace as index/cache;
everything canonical is a readable file in the workspace. Based on the legend
project's proven scaffold. Full decisions per feature live in
`docs/superpowers/specs/`; the condensed map lives in `docs/ARCHITECTURE.md`
(created with the foundation implementation).

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
   reference tree itself. After this phase Valea is a demo-able product with
   no accounts connected. *(shipped, pending merge; spec:
   2026-07-10-agent-slice-design.md)*
4. **Mail** — a sync-to-files engine that reads IMAP and normalizes messages
   into `sources/mail/`, following the AI/Review folder flow (replaces the
   mock input). No new agent tool surface — the agent still only reads
   files. *(shipped, pending merge; spec: 2026-07-11-mail-design.md)*
5. **Calendar** — a sync-to-files engine that reads CalDAV / imports ICS
   into `sources/calendar/`, today + week views. Same file-first posture as
   Mail.
6. **Workflows & agents, full depth** — registry UI, context bundles,
   additional harnesses beyond Claude Code, everything the prototype slice
   deferred.
7. **ICM mounts** — named external ICM roots (shared + personal composition)
   in workspace config, own top-level Knowledge sections, per-mount
   writability, namespaced references (`company:icm/…`); the agent slice's
   policy contexts and root lists are already composition-ready for this.

The MVP is complete when the core acceptance scenario runs end-to-end: open
app → move Priya's inquiry to AI/Review → run triage workflow → review the
prepared draft with sources → approve → local draft created, full chain in the
audit log — and "Open the hood" shows the plain files behind all of it.
