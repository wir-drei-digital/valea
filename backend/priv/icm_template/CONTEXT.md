---
format: 1
related_icms: []
---

# {{name}} — router

Find your task, go where the row points. Keep this table current.

| Task | Go here | You'll also need |
| ---- | ------- | ---------------- |
| Anything about a client | `clients/CONTEXT.md` | — |
| Update what Today shows | `today.json` at this root | the shape in `AGENTS.md` |
| Add a new domain of work | create `<domain>/CONTEXT.md`, add a row here | `AGENTS.md` |

<!--
Related ICMs — root CONTEXT.md frontmatter only (nested CONTEXT.md files
route prose; they do not declare context). To give sessions in this ICM
read access to another mounted ICM, list it above:

related_icms:
  - id: <the other ICM's icm.yaml id (UUID)>
    name: <display name>
    entrypoint: CONTEXT.md
-->
