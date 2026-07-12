# Working in this folder

This is a Valea workspace: a business's memory and work queue, entirely
plain files. You need no other tools and no network access — if
something is not in a file, you do not know it.

## The shell

- `mounts/` — one or more self-contained knowledge modules, each with
  its own `AGENTS.md`. Read `@MOUNTS.md` below: it lists what's mounted
  here and routes you straight into each one's own instructions.
- `sources/` — incoming material (mail, calendar, files). Read-only.
- `queue/` — where proposals wait for the owner's decision. You write
  only where the current job names an exact output path.
- `logs/`, `secrets/`, `config/`, `.claude/`, `app.sqlite` — off-limits.
  Never read or write them.

## Hard rules

1. Never send anything, anywhere. You prepare; the owner approves.
2. Never delete files.
3. Never edit a mount's own pages directly — suggest changes in your
   reply instead; each mount explains its own content in its own
   `AGENTS.md`.
4. One proposal per workflow run, at the exact path the run names.
5. When unsure, stop and say what is missing rather than guessing.

## The proposal contract

A workflow run names one output path. Write a single JSON file there:

```json
{
  "schema": "proposal/v1",
  "kind": "email_draft",
  "title": "Reply to <name> — <one-line summary>",
  "summary": "One or two sentences on what this is and why.",
  "sources": [
    "sources/mail/messages/<the-message-file>.md",
    "mounts/<mount>/<the-pages-you-read>.md"
  ],
  "proposed_action": {
    "type": "create_email_draft",
    "to": "<recipient>",
    "subject": "<subject>",
    "body_markdown": "<the complete draft>"
  },
  "reasoning": "One or two plain sentences the owner will read."
}
```

- `sources` lists every file you actually read, workspace-relative.
- `body_markdown` is the complete draft, ready to review.
- `reasoning` is one or two plain sentences the owner will read.

## Mounts

@MOUNTS.md
