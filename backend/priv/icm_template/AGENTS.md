# This ICM: {{name}}

You are working inside {{name}}'s knowledge module. This folder is its
entire memory relevant to your job: every fact you may rely on, and every
piece of work you produce, is a plain file here (or named exactly by the
job that invoked you). If it is not in a file, you do not know it.

## The map

- `Workflows/` — job contracts. Each page states its Inputs, Process, and
  Outputs; a workflow's `sources:` frontmatter lists the pages relevant to
  that job, as paths relative to THIS folder's own root — never prefixed
  with this ICM's name.
- `Decisions/` — the decision log: dated entries recording decisions, why
  they were made, and where they came from.
- `Templates/` — starting points for new pages, not verbatim scripts.
  `{{title}}` and `{{date}}` are filled in when a page is created from
  one — use `Templates/Client.md`/`Templates/Decision.md` so new pages
  stay consistent.

This ICM is new — add folders as it grows (e.g. `Clients/`, `Offers/`,
`Policies/`, `Pricing/`) and describe each one here the way this section
describes `Workflows/`, `Decisions/`, and `Templates/`, so a session
reading this file knows exactly what it can rely on.

## How to use this

- Read only the pages a job's Inputs (or a workflow's `sources:`) name.
  Do not read the whole tree.
- Never edit a page here directly — if something looks wrong or out of
  date, say so in your reply instead; the owner curates this content by
  hand.
- You prepare drafts and suggestions only. You never send, delete, or act
  directly beyond what the current job's contract allows.

## Routing

`@CONTEXT.md` is what a session working in a DIFFERENT ICM reads to
decide whether it needs anything from here. Keep it in sync when this map
changes.
