---
enabled: false
trigger: { type: manual, source: schedule.weekly }
sources:
  - { id: open_queue, type: queue, required: true }
  - { id: recent_mail, type: email, path: "sources/mail/normalized/*" }
risk_level: low
approval:
  required: true
  reason: The weekly review is read by the owner before anything changes.
  actions: [create_brief]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# Weekly Admin Review

Summarizes the week's open loops for the owner. Not active yet — scheduled
triggers arrive in a later phase.

## Inputs

| Input | Where |
| --- | --- |
| Open queue items | `queue/pending/` |
| Recent mail | `sources/mail/normalized/` |

## Process

1. List open loops: unanswered inquiries, pending approvals, overdue
   follow-ups.
2. Write a short review with one suggested next step per loop.

## Outputs

One `proposal/v1` file at the exact path the run names. Do not send
anything.