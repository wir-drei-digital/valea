---
enabled: true
trigger: { type: manual, source: decisions.digest }
sources:
  - { id: decisions_digest, type: file, required: true }
  - { id: decision_log, type: icm, path: "Decisions/2026.md" }
risk_level: medium
approval:
  required: true
  reason: Memory updates must be reviewed before they change business memory.
  actions: [apply_page_content]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---
# Distill Decisions

## Inputs

| id | what it is |
| --- | --- |
| decisions_digest | A digest of recently decided queue items, compiled by the app. |
| decision_log | The mount's chronological decision log. |

## Process

1. Read the digest. Look for durable decisions: a rejection with a reason, a repeated pattern of approvals, anything that changes how future work should be prepared.
2. Read the decision log and any page a candidate decision touches. Do not re-propose anything the log or the pages already record.
3. For each durable decision, propose a memory update (see the memory-update contract in the root AGENTS.md): append an entry to the decision log page, and — when a decision contradicts an existing page (pricing, policies, tone) — propose the correction to that page too.

## Outputs

Zero or more memory-update pairs under the staging `proposals/` folder. No email drafts. If the digest holds nothing durable, write nothing and say so.
