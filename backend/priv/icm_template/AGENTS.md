# {{name}} — agent map

This folder is an ICM: a portable, user-owned context project. You (the
agent) interpret its prose — nothing in here is a schema, and no folder
name is magic. Start at `CONTEXT.md`, the router, before any task.

## How this ICM is organized

- `CONTEXT.md` — the router: a prose table mapping tasks to places. Every
  domain folder that grows keeps its own `CONTEXT.md` router too.
- One folder per domain of work (`clients/` is the seeded example). Keep
  documents next to the work they describe; nesting is fine and normal.
- `docs/` inside a domain folder holds its reference material.
- Prose files are Markdown. Name files lowercase-with-dashes.

## Conventions you maintain

### today.json

`today.json` at this ICM's root is what Valea's Today page renders. Valea
never writes it — you do, whenever you prepare work or notice open loops.
All fields optional; unknown fields are ignored:

    {
      "updated_at": "2026-07-16T08:00:00Z",
      "prepared": [{ "title": "…", "summary": "…", "page": "relative/path.md" }],
      "open_loops": [{ "title": "…", "source": "…" }],
      "notes": ""
    }

`page` values are paths relative to this ICM's root; Valea renders them as
links into Knowledge.

### Secrets

Documents store POINTERS to secrets ("the API key lives in the system
keychain"), never values. Valea denies reads and writes on `secrets/`
folders, `.env*` files, key material (`*.pem`, `*.key`), and anything named
like credentials — do not route work through such files.

### Routing

When you add a folder or a significant document, add a row to the nearest
`CONTEXT.md` so the next session can find it without searching.

## Working style

- Follow the routing tables rather than globbing the tree.
- Every file change you make is reviewed live by the user through Valea's
  permission gate — propose precise, minimal edits.
