# Agent-native ICMs (Spec D) — design

Status: approved 2026-07-16 (design sections approved in session; spec pending user
review). Builds on `docs/notes/2026-07-16-comprehensive-app-review.md` and its two
evidence studies (`2026-07-16-reference-icm-study.md`,
`2026-07-16-valea-rigidity-map.md`). Successor direction to the shipped Spec B
workflow pipeline; ICM project workspaces (merged 2026-07-16) is the substrate and
is not reopened here.

## Goal

Valea stops interpreting ICM structure and becomes cockpit + guardrails + building
blocks. The agent is the interpreter of an ICM's prose; Valea supplies containment,
identity, approval-by-ask, sync, and UI. Concretely: delete the workflow subsystem,
replace "run" with one session primitive, make the Today cockpit a view over a file
the agent maintains, and remove every structural assumption the reference-ICM study
showed real ICMs violate.

**Design north star (user's own methodology):** workflows are freeform prose
interpreted by an LLM; routing is prose tables in `CONTEXT.md` at every level;
structure is siloed by workflow, not file type; the human stays in the loop through
the harness ask-gate; unattended work is deterministic scripts (Spec F), not agent
pipelines. Remove complexity now, before it accumulates as debt.

## Final product contract (updated)

> A Valea workspace is a private local operational profile. An ICM is a portable
> user-owned context project whose internal structure belongs to the user and their
> agent — Valea never requires reserved folders, frontmatter contracts, or schemas
> inside it. Every agent session runs inside exactly one primary ICM with only the
> context the ICM or task explicitly names, and every side effect passes through
> the live permission ask-gate. Valea's UI renders what the files say.

## A. Deletions (the workflow subsystem)

Backend — remove modules and all references:

- `Valea.Workflows` (registry, frontmatter parse, `get/2`, `triage_path/distill_path`)
- `Valea.Workflows.Runner` (incl. `run_generated`, staging lifecycle, `run.json`
  sidecar, prompt builder, exact-grant assembly — the grant mechanism itself moves
  to sessions, §B)
- `Valea.Workflows.MemoryProposal`, `Valea.Workflows.Distill`
- `Valea.Queue`'s proposal kinds and executors: `memory_update` + `email_draft`
  validation (`valid_payload?`, `valid_action_for_kind?`, `valid_action?`), the
  `approve/2` kind dispatch, `apply_page_content/2`, crash recovery for memory
  items, decided-item digest support. The queue directories in the workspace
  template (`queue/{pending,processing,approved,rejected,applied,staging}`) are
  removed from the template; `Valea.Audit` stays.
- `Valea.Agents.SessionSettings`: the `@workflow_contract` block and the
  `kind == "workflow"` branch of `context/1`.
- `Valea.Agents.RiskTier`: the `Workflows/` prefix tier (see §D for its
  replacement); permission-item enrichment stays for instruction files.
- `Valea.ICM.References`: the workflow-frontmatter reference union
  (`workflows_dir/1`, `workflow_files/1`, frontmatter `sources:` rewrite). Page-link
  rename integrity remains `Valea.ICM.LinkRewrite`'s job, unchanged.
- RPC surface: `list_workflows`, `run_workflow`, `distill_decisions`,
  `list_queue_items`, `approve_queue_item`, `reject_queue_item` (and any queue
  RPCs), plus their client wrappers and regenerated codegen.
- `Valea.Cockpit`: seeded demo content and `triageWorkflowPath`/`distillWorkflowPath`
  (replaced by §C).

Frontend — remove: the `/workflows` route and `WorkflowCard`/`workflowHref`,
`triage-workflows.ts` and the Mail "Run triage" picker, the Distill button and
`InquiryTriageCard`/`PreparedItemCard` demo plumbing, `/queue/[run_id]`,
`ApprovalCard`, `MemoryUpdateReview`, `memory-review.ts`, `queue-ops.ts`,
`queue.svelte.ts`, and the queue portions of `audit/sentence.ts` (audit keeps
rendering historical entry types generically — an unknown audit type renders as a
neutral sentence, never crashes).

Sidebar/nav: the "Workflows" nav item is removed. `Workflows` kebab item in
`IcmProjects` ("Show workflows") is removed.

Also delete the now-dead `PermissionPolicy.decide_legacy/2` branch and its tests
(final-review fast-follow), and correct the module's and `ARCHITECTURE.md`'s
"callers not yet migrated" claims.

No prod users: deletions are clean cuts with test updates, no migrations, no
backwards compatibility. Historical audit lines from deleted flows remain on disk;
the audit renderer treats unknown types leniently.

## B. The session-with-context primitive (what replaces "run")

One kind-agnostic extension to session creation. `create_agent_session` gains two
optional arguments:

- `context_doc` — an ICM locator (`{kind: "icm", icm_id, path}`) of a document to
  execute/consult. Effect: the session's opening prompt (FE-composed first message)
  references the document by its cwd-relative path ("Read and follow
  `finances/workflows/inbox-triage.md`…" — exact copy decided at plan time). No
  server-side prompt template beyond this; the document is the program.
- `input` — an ICM or workspace locator granted as an exact read path. Server-side:
  `SessionScope.resolve/1` folds it into `read_roots` exactly as workflow inputs
  were (resolve at launch, fail-closed `:input_unavailable`), now for any session.
  `session/v1` metadata records both fields for provenance; audit records session
  start with them.

The session `kind` field collapses to `"chat"` (kept in the schema for future
kinds). Everything else about sessions is unchanged: cwd = primary ICM root,
related ICMs by declaration, managedSettings posture, PermissionPolicy answering
the ask-gate, PermissionCard line-diffs as the human-in-the-loop surface.

Entry points that use it:
- Knowledge page kebab / editor: "Start a session with this page" (context_doc).
- Mail message view: "Start a session about this message" (input = the message
  file locator) — replaces "Run triage" (§E).
- Plain chat `+` stays as-is (no context).

Future (explicitly out of scope, noted for Spec F): scheduled/headless sessions
and a "request user input" MCP tool for them.

## C. Today = a file the agent maintains

The cockpit renders files instead of seeded fiction:

- Contract: `today.json` at an ICM's root (tree-visible; not dot-prefixed).
  Lenient schema, all fields optional, unknown fields ignored:
  ```json
  {
    "updated_at": "2026-07-16T08:00:00Z",
    "prepared": [{ "title": "", "summary": "", "page": "relative/path.md" }],
    "open_loops": [{ "title": "", "source": "" }],
    "notes": ""
  }
  ```
  `page` values are ICM-relative paths rendered as Knowledge links. Malformed JSON
  → the ICM's section shows a calm "today.json couldn't be read" note, never an
  error state.
- Aggregation: `Valea.Cockpit.today/0` merges `today.json` across enabled ICMs
  (config order, each section labeled with the ICM name — provenance chips stay)
  plus live state that Valea owns: mail counts (existing), recent sessions.
  Schedule data remains out until calendar exists (Spec F).
- Empty state: no `today.json` anywhere → a quiet explanation of the convention
  with a "learn how" pointer, not demo content.
- Who writes it: agents (the seeded CLAUDE.md documents the convention, §D) and,
  later, Spec F scripts. Valea itself never writes it.
- Watcher: `today.json` changes ride the existing `icm_changed` events; the FE
  cockpit store refreshes on them.

## D. Dynamic-tree riders

1. **Starter seed (`priv/icm_template`) → the 3-layer prose pattern.** New
   contents: `icm.yaml`; `AGENTS.md` (the map: folder tree, naming rules, the
   `today.json` convention, secrets rules — under ~100 lines); `CLAUDE.md` as a
   relative symlink to `AGENTS.md` (fallback for platforms/filesystems without
   symlinks: a one-line `@AGENTS.md` import file); `CONTEXT.md` (prose router
   table `| Task | Go here | You'll also need |`, plus the root-level
   `related_icms:` frontmatter block documented correctly this time); one example
   domain folder (e.g. `clients/`) containing its own `CONTEXT.md` and `docs/`.
   No `Workflows/`, `Templates/`, `Decisions/`. Existing template tests replaced.
2. **Template discovery goes recursive.** The FE "Start from template" picker
   discovers any folder named `templates/` (case-insensitive) at any depth in the
   selected ICM's tree, listing its `.md` files grouped by their parent path. The
   backend RPC already supports arbitrary paths — FE-only change plus tests.
3. **Depth-aware RiskTier.** `classify/1` returns `"high"` for: basename in
   {`AGENTS.md`, `CLAUDE.md`, `CONTEXT.md`} at any depth (case-sensitive
   basenames, any directory), and `icm.yaml` at root. The `Workflows/` prefix rule
   is deleted. Everything else in an ICM stays `"medium"`; workspace targets keep
   current behavior.
4. **Adopt-a-folder mounting.** `inspect_icm` on a manifest-less folder returns
   `ok: false, reason: "no icm.yaml…", adoptable: true` (adoptable = directory
   exists, passes boundary checks, no manifest). Onboarding "Use existing" and the
   sidebar Mount flow then offer one consent step — "Add a small identity file
   (icm.yaml) so Valea can recognize this folder" — which mints
   `{format: 2, id: uuid, name: <basename>}` (name editable) and mounts. The only
   write is that one file. `inspect_icm`'s `format: 1` handling is aligned with
   mounting (both accept, both report).
5. **ICM-internal secrets deny-by-default.** `PermissionPolicy` denies read/write
   on paths matching, at any depth inside any ICM root: a `secrets/` directory
   segment, `.env` / `.env.*` basenames (except `.env.example`), `*.pem`, `*.key`,
   and basenames containing `credentials`. Deny, not ask (mirrors the
   workspace-protected tier); the managedSettings posture mirrors the same
   patterns. Doctor's `secrets_hygiene` warning stays as the visibility layer.
   No per-ICM override in this spec (add later if a real need appears).
6. **Docs drift fixes.** Remove the page-level `related_icms` teaching from the
   template; update `ARCHITECTURE.md`/`VISION.md` for everything this spec deletes
   and adds; `AGENTS.md`-map guidance replaces workflow-contract prose.

## E. Mail interim (until Spec E)

Reading, sync, the inbox list, and the message view are untouched. "Run triage" is
replaced by "Start a session about this message" (§B input grant). Drafting is an
ordinary agent activity: the agent writes a draft file (e.g. under the ICM or
`sources/mail/drafts/`) through the ask-gate. `MailboxOps` (append-to-Drafts,
archive) loses its only caller with the queue and is removed along with it; outbound
mailbox mutations are manual until Spec E designs maildir + its own approval
surface. `Valea.Mail.Doctor`'s workflow-contract check is removed with the contract.

## Error handling

- `context_doc`/`input` resolution failures at session start: fail-closed with the
  existing locator error atoms; FE shows the calm error inline at the entry point.
- `today.json`: parse errors surface per-ICM as a note; never block the cockpit.
- Adopt-a-folder: minting failures (permission, disk) surface the OS reason; no
  partial mount (mint then mount, mint failure aborts).
- Unknown audit entry types (historical queue/workflow lines): rendered as a
  generic "something happened" sentence with the raw type shown, never a crash.

## Testing strategy

- Deletion completeness: repo greps for removed module names in lib/test/src must
  be zero (doc/spec hits fine) — same clean-cut bar as Phase 11.
- Session primitive: scope tests (input grant folds into read_roots for chat
  sessions; fail-closed on unavailable input; metadata carries context_doc/input);
  policy tests unchanged plus the secrets-deny patterns (positive + `.env.example`
  negative + segment-boundary cases).
- Cockpit: unit tests over the lenient parser (valid, partial, malformed, absent);
  aggregation order + provenance.
- RiskTier: depth cases (nested CONTEXT.md high; `notWorkflows/x` medium;
  `foo/AGENTS.md` high).
- Adopt: inspect → adoptable flag; mint content; boundary-rejected folder not
  adoptable.
- Template discovery: nested `templates/` found, case-insensitive, grouped.
- FE suites updated for every removed surface; acceptance run re-scoped (S6's
  workflow scenario is superseded — its replacement: "start a session with a
  workflow doc + input, observe ask-gated execution", which the 2026-07-16 live
  verification already demonstrated end-to-end).

## Out of scope (pointers)

- **Spec E — mail as maildir**: canonical Maildir store, agent read-only access,
  outbound ops approval surface, md-mirror/SQLite as derived views.
- **Spec F — calendar + deterministic steps**: ics building block; script contract
  (approve-once by path+hash), scheduler UI; headless sessions + the
  "request user input" MCP tool idea (user, 2026-07-16); `today.json` writers.
- Per-ICM overrides for the secrets deny-list; pinning/bookmarks for runnable
  docs (only if a real need emerges — the agent + CONTEXT.md routing is the
  default answer).
