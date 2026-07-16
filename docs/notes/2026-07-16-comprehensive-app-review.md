# Comprehensive application review — Valea vs. real ICMs

Date: 2026-07-16, at `feat/workspace-profiles` @ d099c5b (post icm-project-workspaces,
final review "ready to merge"). Requested lens: the workflow model is suspected too
rigid; the goal is fully dynamic ICMs plus email/calendar offered as filesystem
building blocks (maildir) so the agent connects blocks instead of Valea running fixed
pipelines.

Evidence base (both in `.superpowers/sdd/`, gitignored scratch; key content summarized
here): `reference-icm-study.md` — structural grammar of two real, daily-used ICMs
(`~/Development/workspace`, `~/Development/life`); `valea-rigidity-map.md` — file:line
map of every constraint Valea imposes. This document is findings + recommendations
only; no code was changed.

---

## 1. Verdict on the hypothesis

**Confirmed, strongly.** The two real ICMs and Valea's shipped model disagree at
almost every point where Valea imposes structure:

| Valea assumes | Real ICMs do |
|---|---|
| Workflows only in top-level `Workflows/*.md`, capital W (`workflows.ex:226-231`) | workflows live at any depth, lowercase (`life/finances/workflows/`, `clients/…/patterns/workflows/`), and workflow-shaped content also lives in `docs/` |
| YAML frontmatter contract gates registration (`workflows.ex:249-270`) | **zero** real workflows carry frontmatter across ~150+ md files; shape = prose + numbered steps + an "Inputs and Outputs" table |
| Central `Templates/`, `Decisions/` conventions (seeded by `priv/icm_template`) | templates scatter per-domain; a `Decisions/` folder exists nowhere — decisions are content, not a content type |
| Routing via root `CONTEXT.md` **frontmatter** (`context.ex:64-99`) | routing is prose tables (`\| Task \| Go here \| You'll also need \|`) at every level, designed to be read by an LLM, never parsed |
| md-only editable tree; scripts not modeled | content is majority non-markdown (csv/yaml/pdf/docx/eml/images); scripts are first-class (43 Python files in `workspace/`), living beside the docs that describe them, some run by systemd timers |
| mail = IMAP sync → bespoke md mirror + SQLite; agent sees one granted file per run | mail = read-only Maildir accessed by path through an anchor register; the user has a written, reusable maildir-parsing pattern doc |
| every workflow step mediated through the interactive ask-gate | the user's own automation minimizes LLM involvement: one narrow `claude -p --allowedTools Read` call wrapped in deterministic Python that owns all side effects |

The sharpest finding is philosophical, not technical: the user's own product document
(`workspace/brand/icm-toolunabhaengigkeit.md`) defines ICM as "folder structure as
agentic architecture … no proprietary system in between", and
`_system/architecture.md` rule 1 is "workspaces are siloed **by workflow, not by file
type**" — Valea's `Workflows/`/`Templates/`/`Decisions/` scaffold is precisely a
file-type silo. Valea currently ships a workflow *product*; the methodology it serves
is an *interpreted prose* system where the agent is the interpreter.

**Design principle that falls out: Valea should stop being the interpreter of ICM
structure and become the cockpit + guardrails + building blocks. The agent interprets
the ICM; Valea supplies containment, approval, identity, sync, and UI.**

## 2. What holds up (keep, unchanged)

The entire security core survives this review intact and is the part worth
protecting through any redesign:

- Hidden id-based workspaces; ICMs external/portable/by-reference; config-truth
  mount registry with fail-closed boundaries.
- Session containment: cwd = primary ICM, explicit related-ICM declaration, exact
  input grants, in-memory managedSettings + PermissionPolicy callback (live-proven).
- Stable locators re-resolved at approval; the approval queue *concept* (fail-closed,
  hash-guarded, audited); the audit trail.
- The editor, scan search (already recursive/depth-free — the one subsystem that got
  it right), backlinks, byte-surgical rename.
- Onboarding (Start fresh / Use existing), sidebar ICM projects, keychain handling
  (closure-wrapped credentials).

Notably, "mail is read-only for agents; every outbound action approval-gated" is a
rule the user independently wrote into three of their own docs — Valea's approval
posture is the *correct* instinct; it's the fixed pipeline around it that isn't.

## 3. Findings → recommendations

### R1 — Invert the workflow model (the big one)
Today a workflow is a schema: frontmatter-gated registration in one reserved folder
(`workflows.ex:226-231,249-270`), a hardcoded prompt, and a proposal contract taught
only by Elixir source (`session_settings.ex:23-76`). Real workflows are prose
interpreted by the agent. Recommendation: **a workflow is any document the user
points an agent at.** Concretely:
- Discovery becomes recursive and convention-lenient (any `workflows/` directory,
  any case, any depth — plus user-pinnable "run this" bookmarks on arbitrary pages),
  with frontmatter as optional *enrichment* (risk level, approval mode), never a gate.
- The Runner's job shrinks to: create a contained session whose prompt is "execute
  this document" + exact input grants + staging for proposals. The document itself
  carries the instructions (as real ICMs already do).
- Downstream fixes ride along: References rename-rewrite (`references.ex:262-269`)
  and RiskTier (`risk_tier.ex:26,35-41`) must become depth-aware (R7), and the FE's
  literal-filename triage matching (`triage-workflows.ts:29`) becomes a pin/selection.

### R2 — Email as a filesystem building block (maildir)
Today: IMAP → bespoke YAML-frontmatter md mirror (`message_file.ex:118-142`) +
SQLite; the agent never sees a mailbox, only one granted file. Recommendation:
**Valea's mail sync writes a standard Maildir** (e.g. `sources/mail/<account>/{cur,new,tmp}`)
as the canonical on-disk store; the md mirror (if kept at all) and the SQLite index
become derived views for the UI. Agent sessions can be granted **read-only** access
to the maildir root (matching the user's own hard rule), and any workflow/script can
parse it with standard tooling — exactly the user's proven Thunderbird pattern,
minus the Thunderbird prerequisite. Valea keeps what it's uniquely good at:
credentials in the keychain, sync, the inbox UI, and approval-gated outbound ops
(draft/send/archive). This also serves the observed client demand ("Mails geordnet")
without requiring a third-party client configured just-so.

### R3 — Calendar: build it as a building block from day one
Nothing is implemented (`calendar.yaml` vocabulary is pre-committed, zero domain
code) — so there is nothing to migrate. Same shape as R2: CalDAV/ICS sync → plain
`.ics` files under `sources/calendar/`, read-only agent access, UI index derived.

### R4 — A script/deterministic-step contract
Real ICMs run Python/Bash/PowerShell as load-bearing steps; Valea has no notion of
it — every `Bash` call falls to `:ask` because `extract_paths/1` only understands
file paths (`permission_policy.ex:408-414`). Recommendation: design (in a proper
brainstorm — this is security-sensitive) a first-class "deterministic step": a
script the user approves once (identity = path + content hash), runnable by the
agent or scheduler, output captured as a normal proposal input. The user's own
beleg-sync philosophy ("the LLM only reads; fixed code makes every decision") is the
design brief.

### R5 — Fail-loud, extensible proposal kinds
The kind vocabulary is two literals enforced in ≥4 places, and `Queue.approve/2` is
a 2-way `"memory_update" | _` dispatch (`queue.ex:189-192`) where an unknown kind
would silently execute as an email draft. Even without new kinds, make the dispatch
N-way with an explicit error for unknown kinds. If R1/R4 land, kinds become a
registry (e.g. `page_update`, `email_draft`, `command_run`, `file_drop`).

### R6 — Let the tree be the user's tree
- Stop seeding `Workflows/Templates/Decisions` scaffold in `priv/icm_template`;
  teach the 3-layer prose pattern instead (CLAUDE.md map, CONTEXT.md router tables,
  per-domain `docs/`) — i.e. seed the user's *actual* methodology.
- Templates picker: recursive discovery (FE-only fix, `template-options.ts:30-40`).
- Assets: place uploads beside the page (or in a sibling `assets/`) instead of one
  flat mount-root `Assets/` (`files_controller.ex:113-131`).
- Respect `_underscore` = reference/meta convention in tree display and search
  ranking. Consider first-class preview for common non-md types (csv, pdf, images)
  — the tree already lists them as leaves.
- Fix the shipped-template drift: `priv/icm_template/CONTEXT.md` teaches a
  page-level `related_icms:` convention the code doesn't implement.

### R7 — Depth-aware risk tiering
`RiskTier.classify/1` treats only exact top-level `AGENTS.md`/`CLAUDE.md`/`icm.yaml`
and the `Workflows/` prefix as high (`risk_tier.ex:26,35-41`). Real ICMs put
instruction files (`CONTEXT.md`, nested `CLAUDE.md`) at every level. High tier should
match instruction-bearing basenames at any depth and any `workflows/` segment,
case-insensitively. (Also a quiet trust gap today, not just rigidity.)

### R8 — ICM-internal secrets deserve policy, not just a doctor warning
`workspace/secrets/` (gitignored, one file per service) is the user's real
convention; Valea's deny-list stops at the workspace root — an ICM-internal
`secrets/` or `.env` is ordinary readable content (`session_settings.ex:90-95`,
doctor warns only). Recommendation: default-deny well-known secret patterns inside
ICMs (`secrets/`, `.env*`, `*.pem`, `*credentials*`) at the PermissionPolicy layer,
overridable per-ICM.

### R9 — Mounting real, pre-existing ICMs must be one gentle step
Both reference ICMs would fail `inspect_icm` today ("no icm.yaml found") — `life/`
isn't even a git repo. The manifest is the right identity anchor, but onboarding
should offer "adopt this folder": mint the one small `icm.yaml` (with consent) and
mount — never require the user to hand-author it. (Also: `inspect_icm` rejects
`format: 1` manifests more strictly than mounting does — align.)

### R10 — Prove the harness seam
Both real ICMs maintain `CLAUDE.md ⇄ AGENTS.md` symlinks for Claude-Code/Codex
dual-use — multi-harness is the user's working reality. The seam has one
implementation with Claude-specific mechanics inside (`_meta.claudeCode` channel,
provider env vars in the "generic" allowlist, `env.ex:8`). A second implementation
(Codex) is the only proof of genericity; until then, keep the seam honest about
what's Claude-specific.

## 4. Suggested sequencing (for discussion, not started)

1. **Spec D brainstorm — "Dynamic ICMs":** R1 (workflow inversion) + R6 + R7 + R9 +
   R5, one coherent redesign of how Valea reads an ICM. Highest leverage; mostly
   deletes schema rather than adding it.
2. **Spec E brainstorm — "Mail as maildir":** R2 (+ its approval-ops surface).
   Bounded, high-value, aligns Valea with the user's proven pattern; decides the
   fate of the md-mirror + SQLite index as views.
3. **Spec F — "Calendar + deterministic steps":** R3 + R4 together (both are "new
   building block + scheduler/exec contract" shaped). R4 needs the most careful
   security design.
4. R8 and R10 can ride along wherever they fit first.

Backlog from the branch's final review remains separate and unaffected: delete the
dead `decide_legacy` branch, `Mail.Index`/Repo cold-run race, "New workspace"
switcher entry.
