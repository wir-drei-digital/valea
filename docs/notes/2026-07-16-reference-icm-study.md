# Reference ICM Study — Structural Grammar of Real, Organically-Grown ICMs

Study of two real ICMs the user works in daily with claude-code:

- `/Users/daniel/Development/workspace` ("w3d" — wirdrei.digital, business; git repo, 47 commits)
- `/Users/daniel/Development/life` (personal; **not a git repo at all** — no `.git`, no top-level `.gitignore`, only a workflow-local `.gitignore`)

Goal: extract structural rules a system (Valea) would need to support natively, as
counter-evidence to Valea's current rigid model (workflows only in top-level
`Workflows/*.md` with YAML frontmatter id/what-it-is/inputs contract; templates only in
top-level `Templates/`; decisions in `Decisions/`; routing via root CONTEXT.md
frontmatter; `.md`-only knowledge tree; no scripts).

---

## 1. Workflow Shapes

**No workflow file in either ICM uses YAML frontmatter.** Grepped every `.md` file in
both repos for a leading `---` frontmatter block or `id:`/`what-it-is:` fields: zero
hits among real workflow content. The only frontmatter in the whole corpus is (a)
pandoc-style `title/author/date/version/lang` metadata on **workshop handouts**
destined for PDF rendering (`workspace/workshops/prompting-1x1/handouts/ki-checkliste-alltag-v1.0.md`)
and (b) vendored third-party Anthropic `SKILL.md` files under
`clients/_icm-playbook/skills-ref/office-skills/public/{docx,pdf,pptx,xlsx}/SKILL.md`
(reference snapshots, not authored here). Every real workflow is freeform prose with
markdown tables and numbered steps.

**Workflow dirs found** (`find -iname workflows`, any depth):
`workspace/workflows/`, `life/finances/workflows/`, `life/communications/workflows/`,
`workspace/clients/_icm-playbook/patterns/workflows/`,
`workspace/clients/_icm-playbook/blueprint/production/workflows/`.
Plus **workflow-like content living outside any `workflows/` dir**: a `docs/` file titled
literally `# Skill: PPTX Build Workflow` (`workspace/workshops/docs/pptx-build-workflow.md`),
runbook-shaped docs in `workshops/docs/` (deck-building, fact-checking-workflow,
writing-handouts), and a numbered pipeline pattern doc
(`clients/_icm-playbook/patterns/workflows/thunderbird-maildir-email-parsing.md`).
Workflow-shaped content is **wherever the domain lives**, not confined to a reserved dir.

**Representative sample (structure survey):**

| File | Shape | Frontmatter | Scripts referenced | I/O convention |
|---|---|---|---|---|
| `life/finances/workflows/invoice-processing/CONTEXT.md` | router: prose + stage table (01/02/03) + status-value enums | none | none | logical folders (`inbox/`, `review/`, `excluded/`, `categories/*/Archive/`) |
| `.../invoice-processing/01-email-intake.md` | numbered steps, prose | none | none | `## Inputs and Outputs` markdown table: Location \| Access \| Use |
| `.../invoice-processing/02-categorize-and-log.md` | numbered steps | none | none | same I/O table convention |
| `.../invoice-processing/03-business-copy.md` | numbered steps, approval gate | none | none | same I/O table convention |
| `.../invoice-processing/paths.md` | anchor register (not a workflow but load-bearing) | none | `resolve.sh`/`resolve.ps1` (playbook version) | logical anchor → `paths.local` base + relative path |
| `life/communications/workflows/inbox-triage.md` | 4-line numbered checklist | none | none | none — pure judgment task |
| `workspace/workflows/docs/beleg-sync.md` | architecture doc + component table + failure-mode table | none | `process_belege.py` + systemd units, explicitly | ASCII pipeline diagram, "LLM only as eyes" |
| `workspace/workshops/docs/pptx-build-workflow.md` | "Skill:" heading, numbered steps + code block | none | `scripts/pptx_helpers.py`, `pptx_to_pdf.sh`, `render_thumbnails.sh` | file path per step |
| `workspace/workshops/docs/deck-building.md` | role + pipeline + defaults table | none | `build.py`, `pptx_helpers.py`, `wirdrei_template.py` | defaults table (Setting \| Default) |
| `clients/_icm-playbook/patterns/workflows/thunderbird-maildir-email-parsing.md` | reusable **pattern** doc: prereqs, why, anchor pattern, generic 6-step shape, failure handling, adaptation checklist | none | none (pattern, not instance) | anchor table + checklist |
| `clients/kita-villa-vesta/.../01_auskunft/CONTEXT.md` | numbered workflow inside a live client engagement | none | `resolve.ps1 [ANKER]` | anchor table scoped to read-only |
| `skills/github.md` | flat how-to reference, not a workflow at all | none | git/gh CLI | n/a |

**Composition:** workflows call each other by stage number (`01-email-intake.md` →
`02-categorize-and-log.md` → `03-business-copy.md`), reference sibling docs by relative
path in prose ("Details: `workflows/docs/beleg-sync.md`"), and a workflow **router**
(`CONTEXT.md` inside the workflow folder) lists the stage table plus non-negotiable
boundaries and a lifecycle-value glossary (`local_status`, `bookkeeping_status`, `card_scope`
enums) — state machine semantics expressed in prose, not schema.

---

## 2. Scripts & Executables

Scripts are **not excluded** — they're a first-class, load-bearing part of these ICMs.
Languages found: Python (43 files in workspace), Bash/`.sh` (4), PowerShell `.ps1` (3),
Node `.mjs` (4), plus systemd unit files (`.service`/`.timer`).

Classes observed:
- **Data-pull + transform (pipeline):** `clients/_docs/filter/stage12_filter.mjs` →
  `stage2_candidates.csv` → `stage3_enrich.mjs` (calls Zefix REST API, rate-limited,
  cached in `zefix_cache.jsonl`) → `stage3_filtered.csv` → `stage45_shortlist.mjs` →
  `shortlist_AG.csv`. Documented as a "Trichter" (funnel) table: stage → script → row
  count, in `clients/_docs/filter/README.md`.
- **Automation w/ LLM-in-the-loop, deterministic wrapper:**
  `workspace/workflows/beleg-sync/process_belege.py` — a single `claude -p` call with
  `--allowedTools Read --max-turns 3` reads *only* a receipt image and returns JSON;
  every decision after that (numbering, renaming, CSV append, git commit/push, dedup by
  SHA-256) is deterministic Python. Doc states the philosophy explicitly: *"Der LLM
  liest ausschliesslich das Bild und liefert JSON... Er hat nur das Read-Tool — kein
  Write, kein Bash, kein Git. Alle Entscheidungen trifft fixer Python-Code."*
- **Publish/render:** `workspace/documents/render.py` (YAML → .docx → .pdf, Swiss QR-bill,
  self-bootstrapping `.venv`), `workshops/templates/deck-master/build.py` (python-pptx),
  `workshops/scripts/decks/pptx_to_pdf.sh`, `workshops/scripts/handouts/md_to_pdf.sh`
  (pandoc + LaTeX).
- **Anchor resolution (infra utility):** `clients/_icm-playbook/templates/icm/scripts/resolve.sh`
  / `resolve.ps1` — parses `paths.md` + `paths.local`, resolves logical anchors to real
  paths, has a `-Check`/`--check` health-check mode meant to run at every session start.
  Instanced live in `clients/kita-villa-vesta/projekt/haupt-icm/scripts/resolve.ps1`.

**Invocation:** always from prose ("Run `python3 decks/<name>/build.py`"), never from a
Makefile/justfile — none exists in either repo. Two are wired to the OS scheduler
directly: `w3d-belege.service`/`w3d-belege.timer` (systemd user units, installed to
`~/.config/systemd/user/`, hourly + on-login, `Persistent=true`). Scripts sit as
siblings to the docs that describe them (`workflows/beleg-sync/*.py` next to
`workflows/docs/beleg-sync.md`), not in a separate top-level "scripts" reserved
namespace — except `workshops/scripts/` and `documents/` which do centralize
workspace-level tooling.

---

## 3. Hierarchy & Routing

Both ICMs use the identical **3-layer pattern**, explicitly named and documented in
`workspace/_system/architecture.md`:

```
CLAUDE.md   Layer 1: THE MAP — always loaded. Folder tree, naming, global rules. <200 lines.
CONTEXT.md  Layer 2: THE ROUTER — read at task start. Routes to a workspace. No instructions.
workspace/CONTEXT.md  Layer 3: per-domain role, task-routing table, defaults, folder layout.
```

Both roots symlink `CLAUDE.md` ↔ `AGENTS.md` for cross-harness support (Claude Code vs.
Codex) — but in **opposite directions**: `workspace/AGENTS.md -> CLAUDE.md` (git log:
"add AGENTS.md as symlink to CLAUDE.md for codex support"), `life/CLAUDE.md ->
AGENTS.md`. Neither ICM has a single canonical "primary" file name; both are honored.

Nesting: every workspace subdomain gets its own `CONTEXT.md` (never a `CLAUDE.md`
below root, except two special cases: `clients/_icm-playbook/blueprint/CLAUDE.md` — a
teaching artifact showing what a *nested* greenfield workspace's Map would look like —
and per-client instantiated ICMs like `clients/kita-villa-vesta/projekt/haupt-icm/CLAUDE.md`,
which are effectively separate root ICMs living inside the parent one). Workflow
sub-stages get a second, scoped `CONTEXT.md` (e.g.
`life/finances/workflows/invoice-processing/CONTEXT.md`,
`clients/_icm-playbook/blueprint/production/workflows/CONTEXT.md`) — "sub-routing," per
`docs/context-architecture.md`.

Root `CONTEXT.md` content is a **pure prose table**, not YAML frontmatter: `| Your Task |
Go Here | You'll Also Need |`. No machine-parseable routing metadata exists anywhere —
routing is designed to be read by an LLM, not parsed by code.

**Underscore-prefixed dirs** are a real, load-bearing convention meaning "reference
material / not a live instance, excluded from registries": `workspace/_system/` (system
docs about the ICM itself, explicitly "not a workspace — nothing here is task
material"), `clients/_dream-client/` (persona for pitch roleplay), `clients/_client-acquisition/`,
`clients/_docs/` (lead data), `clients/_icm-playbook/` (the meta-template product
itself). Stated explicitly in `clients/CONTEXT.md`: *"Underscore-prefixed folders (e.g.
`_dream-client/`) are reference material, not real engagements — not billed, not in the
Active Clients table."* Also `_state/` inside a workflow = scratch/intermediate,
"never use it as a record archive" (`invoice-processing/CONTEXT.md`). No `_docs` at
system level distinct from per-domain `docs/` — every domain just gets its own `docs/`
(not underscore-prefixed) for stable reference knowledge, separate from working
folders — this is Principle 3 in `_system/architecture.md`: *"Docs ≠ working files."*

---

## 4. Content Types Beyond `.md`

Extension census (excluding vendored `skills-ref/office-skills` schema dump, which is a
third-party reference snapshot, not organic content): both ICMs are **majority
non-markdown by volume**. `life/`: 88 pdf, 14 md, 11 eml, 3 csv, 2 jsonl. `workspace/`:
151 md but also 43 py, 28 pdf, 22 png, 11 docx, 8 csv, 5 yaml, 5 xml, 4 mjs, jpg, odt,
ods, pptx, jsonl, service/timer files. No `.ics`/calendar file exists in either ICM
(confirmed via `find -iname "*.ics"` — zero hits) despite calendar-adjacent language in
docs (e.g. workshop scheduling) — calendars are not yet a modeled content type here.

Concrete examples:
- **Data files:** `finance/buchhaltung/journal-2026.csv` (accounting journal, GitHub
  renders it as the "online list"), `documents/company.yaml` (sender/bank data consumed
  by `render.py`), `documents/examples/rechnung.yaml` (commented YAML template),
  `life/finances/workflows/invoice-processing/logs/invoice-log-2026.csv`,
  `_state/intake-2026-07-15.jsonl` (append-only intake log), `zefix_cache.jsonl` (API
  response cache).
- **Documents:** `.docx`/`.pdf`/`.ods`/`.odt` invoices, offers, contracts
  (`compliance/contracts/Darlehensvertrag_CHF30000_3Personen.odt`), signed DPAs as PDF
  (`compliance/magus/dpas/DPA_Stripe_.pdf`).
- **Images:** brand team photos (`brand/assets/team/*.png`), receipt photos
  (`finance/buchhaltung/belege/2026/2026-035_2026-06-08_tibits.jpg`), workshop slide
  thumbnails (`workshops/templates/deck-master/out/thumbs/slide-1.png`).
- **Email-ish artifacts:** raw `.eml` files kept as the financial record when an invoice
  is email-only (`life/.../categories/business/Archive/2026-03-21_neon-tech.eml` —
  11 of them), justified in `01-email-intake.md`: *"For Neon..., invoices are email-only... retain an unmodified `.eml` copy as the workflow record."*
- **Referenced-but-external mail store:** Thunderbird IMAP **Maildir** accessed directly
  by path (`THUNDERBIRD_PROFILE_ROOT`), never copied wholesale — only specific
  attachments/bodies are extracted per message. This is the closest thing to a
  "mail integration" pattern in either ICM (see §7).
- **No calendars, no contacts/vCard, no chat-export formats found.**

All non-md content is referenced from `.md` docs by relative path or logical anchor —
never embedded, never duplicated into the doc.

---

## 5. Secrets & Sensitive Data

`workspace/secrets/README.md` states the convention precisely: *"Local-only credential
storage. **Everything in this folder except this README is gitignored**"*. Layered
defense, three tiers always: (1) runtime secrets in runtime stores only (Fly.io secrets,
GitHub Actions secrets, n8n credentials — never as source of truth elsewhere), (2) local
working copies in `secrets/` only, one file per service, named `[service].env` or
`[service].md`, (3) **docs store pointers, never values** — *"key lives in
`secrets/postmark.env`", never the key itself"* — extended to CONTEXT files, how-tos,
and commit messages. A `VAULT.md` (itself gitignored) holds a password-manager lookup
protocol referenced but not shown to the agent directly.

`.gitignore` safety net beyond `secrets/*`: `.env*` (except `.env.example`), `*.pem`,
`*.key`, `*credentials*`, applied tree-wide (`workspace/.gitignore`).

`workspace/_system/secrets-and-large-files.md` draws an explicit line for what **is**
committed despite being binary/sensitive-adjacent: *"regenerable or oversized →
gitignored; a business record → committed. This repo is private; confidential business
documents are acceptable, credentials never."* — hence signed contracts, DPAs, invoices,
and the accounting journal live in git in cleartext, while secrets/API keys never do.

`life/` has no `.gitignore`/git at all at the top level (per §6/finding above) — the
entire personal ICM is local-only, no VCS exposure risk considered necessary; the one
`.gitignore` that exists is scoped to `finances/workflows/invoice-processing/.gitignore`
(protects `_state/`, `paths.local`, per-run artifacts even without a repo, suggesting
the workflow folder was copied from a template that assumed git).

The overlay ICM playbook generalizes this into the **anchor write-boundary**: every
anchor in `paths.md` carries an explicit read/write flag; default is read-only;
"Standard ist Lesen; Schreiben ist die begründete Ausnahme" (`kita-villa-vesta/.../CONTEXT.md`).
Sensitive anchors are flagged inline (`ELTERN_VERTRAEGE ... (sensibel)`,
`FINANZEN ... (sensibel)`).

---

## 6. `.claude/` Directories

Identical, empty scaffolding in both repos: `.claude/{audit,plans,research,reviews,
skill-metrics,solutions}/` — six subdirectories, zero files in any of them, in both
`workspace` and `life`. These are **harness/skill-convention state directories** (created
by Claude Code plugin conventions, e.g. elixir-phoenix's audit/plans dirs or general
skill output locations) that have simply never been populated — not knowledge, not yet
used. `workspace/.gitignore` ignores only `.claude/settings.local.json`; the six
subdirectories themselves are untracked by git (0 files, so nothing to track) but are
**not** gitignored — if populated, they would become part of the committed history. This
means the convention treats `.claude/` as potentially-committed harness output, not
inherently private scratch space (contrast with Valea's typical `.claude/` = ephemeral
per-session working dir).

---

## 7. Email/Calendar Traces

No calendar integration exists in either ICM. Email handling is the richest pattern
here, concentrated in `life/`:

- `life/communications/` is a near-stub workspace (`CONTEXT.md` 19 lines, `docs/email-rules.md`
  5 lines, `workflows/inbox-triage.md` 4 lines) — establishes *rules*, not automation:
  *"Never send, archive, delete, label or forward messages without explicit approval."*
  (`communications/CONTEXT.md`). No drafts/ dir, no message logs exist yet — it's
  intentionally thin/future scaffolding.
- The **real** email-processing engine is `life/finances/workflows/invoice-processing/`
  (fully built, in active use through 2026-07): reads Thunderbird's local **Maildir**
  store directly by path (two IMAP accounts: `danielmilenkovic@proton.me` via `127.0.0.1`,
  `daniel@wirdrei.digital` via `mail.infomaniak.com`), extracts only invoice/receipt
  attachments or bodies, and is explicitly read-only against the mailbox: *"Read email
  only through `THUNDERBIRD_MAIL_STORE`; never alter, move, archive or delete email."*
  (`CONTEXT.md`). Card-type disambiguation logic lives in prose (`01-email-intake.md`):
  *"treat `Visa` as a private-card payment... treat `Mastercard` as a business-card
  payment and exclude it."*
- This pattern is **generalized as reusable playbook material** in
  `workspace/clients/_icm-playbook/patterns/workflows/thunderbird-maildir-email-parsing.md`
  — a prerequisite checklist (Maildir must be selected *before* adding accounts, offline
  sync must be configured), an anchor pattern (`THUNDERBIRD_MAIL = THUNDERBIRD_PROFILE_ROOT
  :: Mail/[account-or-local-folder]`), a generic 6-step shape (discover → deduplicate →
  extract → parse → classify/act → record state), and explicit failure handling. This is
  the user's own answer to "how should an ICM touch a real mailbox" — it is anchor-based,
  read-only-by-default, and treats the mail store as "an external document layer" exactly
  like any client's untouched folder structure.
- `_system/architecture.md` and `icm-toolunabhaengigkeit.md` do **not** mention
  mail/calendar integration wishes directly, but the Kita client ICM's own status notes
  a **deferred** feature: *"(Zukunft: «Mails geordnet» — nicht im aktuellen Paket, später
  eigener Workflow.)"* (`clients/kita-villa-vesta/.../haupt-icm/CONTEXT.md`) — i.e. the
  business already has a client asking for "get my email organized" as a named future
  workflow, not yet built.

---

## 8. The User's Own Stated Principles (Tool-Independence)

`workspace/brand/icm-toolunabhaengigkeit.md` — the internal rationale behind the
company's pitch — is the single most directly relevant document to Valea's redesign
question. Key claims, in the user's own words:

> "ICM = Interpretable Context Methodology — «Folder Structure as Agentic
> Architecture». ... Statt eines komplexen Multi-Agent-Frameworks bildet eine
> Ordnerstruktur mit einfachen Markdown-Dateien die Architektur."

> "Die bestehende Dateiablage des Kunden ist die Lösung. Kein proprietäres System
> dazwischen, das eingerichtet, gelernt und bezahlt werden muss."

> "Dieser Workspace hier ist selbst ein gelebtes ICM-Beispiel" — the ICM they sell IS the
> ICM they work in daily; there is no separate "product" vs. "dogfood" split.

Four customer promises, all directly about *not* being locked into rigid tooling:
(1) "Kein neues Tool, von dem du abhängig bist" — reuse the folders the client already
has; (2) "Keine Abhängigkeit / kein Lock-in" — if the vendor disappears, the filing
system keeps working; (3) "Offene Modellwahl" — the model is swappable at any time;
(4) "Jederzeit weiterentwickelbar — durch uns oder durch dich selbst. Weil es nur Ordner
und Klartext-Dateien sind, ist nichts eine Blackbox." The whole value proposition is
architecturally anti-rigid: plain folders + plain text, adaptable by hand if needed.

`_system/README.md`: *"The one rule above all: the documentation IS the system. An agent
lands here with zero memory and must be able to orient from `CLAUDE.md` → `CONTEXT.md` →
workspace CONTEXT alone. Every change that isn't reflected in those files effectively
didn't happen."*

`_system/architecture.md` states the grammar as five numbered principles: (1) workspaces
are siloed **by workflow, not by file type** — "A workspace earns its existence from a
recurring workflow with its own docs and rules, never preemptively for an artifact
type" (direct rebuttal of "Templates only in top-level Templates/" as a file-type
silo); (2) cross-workspace flow happens through **files and pointers**, not shared
context; (3) docs ≠ working files; (4) file naming = state tracking (`draft` →
`review` → `final` in the filename, not a status field); (5) token discipline — each
CONTEXT.md says what to load *and what to skip*.

`clients/_icm-playbook/docs/context-architecture.md` adds the load-bearing meta-rule:
*"If an agent finds itself reading three workspaces to do one task, the architecture has
a routing bug — fix the `CONTEXT.md`, don't widen the agent."* — routing failures are
fixed by editing prose routers, never by adding structure/schema.

`clients/_icm-playbook/docs/methodology.md` (anchor architecture) is the concrete
technical answer to "how do we stay tool-independent even when we must reach a client's
real, foreign folder structure": one indirection layer (`paths.md` shared register +
`paths.local` per-device root + a resolver script with a `-Check` health mode), so no
`.md` file or script ever hardcodes a physical path. This is the same pattern reused for
the personal ICM's own Thunderbird integration (§7) — the user applies their own client
methodology to themselves.

---

## Grammar Summary — structural rules a system needs to support natively

1. **Workflows are freeform prose+tables, never schema/frontmatter.** No real workflow
   in ~150+ markdown files uses YAML frontmatter or an id/inputs contract; numbered
   steps + a `## Inputs and Outputs` table (Location | Access | Use) is the closest
   thing to a convention, and even that varies per author/domain.
2. **Workflow-like content is not confined to a reserved `Workflows/` folder.** It lives
   in `docs/` (titled "Skill: X"), in `patterns/workflows/`, inside per-item folders, and
   as ad hoc checklists — wherever the owning domain lives.
3. **Numbered-stage pipelines are the dominant multi-step shape**, each stage its own
   file or folder (`01-`, `02-`, `03-` / `01_`, `02_`, `03_`), each with its own scoped
   `CONTEXT.md` when the pipeline is complex enough, composing by relative-path
   reference in prose, not by a call/import mechanism.
2. **Templates are scattered per-domain, never centralized.** `workshops/templates/`,
   `documents/templates/`, `clients/_icm-playbook/templates/` are independent; a
   top-level `Templates/` reserved namespace does not exist and would fight the
   "siloed by workflow, not file type" rule.
5. **There is no `Decisions/` folder anywhere.** Decisions live inline, in the owning
   domain's `docs/` alongside requirements and notes, or as a status line in a
   `CONTEXT.md` registry table (e.g. client engagement status). Decisions are content,
   not a content *type*.
6. **Routing is pure prose tables read by an LLM, never machine-parsed metadata.** Root
   `CONTEXT.md` = `| Task | Go here | You'll also need |`; nested `CONTEXT.md` repeats
   the shape at each level; no frontmatter anywhere in the routing layer.
7. **Scripts are first-class and live beside the docs that describe them**, in whatever
   language fits (Python, Bash, PowerShell, Node), invoked from prose instructions or
   OS schedulers (systemd timers) — never through a Makefile/justfile abstraction.
8. **LLM calls inside automation are minimized and sandboxed by convention**: one
   narrow, single-purpose call (e.g. image → JSON, `--allowedTools Read` only), wrapped
   in deterministic code that owns every decision with side effects (numbering, renaming,
   git commits, dedup). The prose doc states this philosophy explicitly, not just the code.
9. **Underscore-prefix means "reference/meta, not a live instance"** — consistently
   excluded from registries/active-status tables, documented as a convention in the
   owning `CONTEXT.md`, applied at multiple levels (`_system/`, `_dream-client/`, `_state/`).
10. **Content is majority non-markdown**, and markdown files reference it exclusively by
    relative path or logical anchor — csv/yaml/json/jsonl data, pdf/docx/odt/ods
    documents, images, and raw `.eml` messages treated as first-class financial/legal
    records, all committed to git when they're a "business record," gitignored when
    regenerable.
11. **External/foreign storage (a client's drive, a mailbox) is never addressed by
    direct path.** One indirection layer — a shared logical-anchor register (`paths.md`)
    + a per-device local root (`paths.local`, gitignored) + a resolver with a health-check
    mode — is the load-bearing pattern for both real clients (Kita Villa Vesta OneDrive)
    and the user's own mailbox (Thunderbird Maildir).
12. **Mail is treated as read-only external document layer, never mutated.** Every mail-
    touching workflow states explicitly "never alter/move/archive/delete" and requires
    approval before any mailbox-affecting action — this is a hard rule repeated
    independently in three places (personal communications rules, invoice-processing
    boundaries, the reusable Maildir pattern doc).
13. **Two independent root files (`CLAUDE.md`/`AGENTS.md`) are kept in sync via symlink**,
    direction varying per ICM — multi-harness support is assumed, not optional.
14. **`.claude/` accumulates as potential harness output that CAN be committed**, not
    inherently ephemeral/private — only `settings.local.json` is force-ignored; the
    plan/research/solutions/audit/reviews convention exists but was empty in both real
    ICMs studied (used elsewhere by skills, not yet by these specific projects).
15. **Not every real ICM is version-controlled.** `life/` has no git at all; workflow
    folders bring their own local `.gitignore` defensively even without a repo. A system
    modeling "the knowledge tree" cannot assume git is present.
16. **File-naming carries state**, not a frontmatter/database field: `draft` →
    `review` → `final` suffixes, `_v1.1` version suffixes (highest = current, old kept),
    `YYYY-MM-DD_vendor.ext` for records — status is legible from a folder listing alone.
