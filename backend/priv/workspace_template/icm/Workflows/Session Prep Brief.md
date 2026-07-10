---
enabled: false
trigger: { type: manual, source: calendar.upcoming }
sources:
  - { id: upcoming_event, type: calendar, required: true }
  - { id: client_page, type: icm, path: "icm/Clients/*" }
  - { id: brief_prompt, type: prompt, path: "prompts/session_brief_writer.md" }
risk_level: low
approval:
  required: true
  reason: Briefs are reviewed before they land on the desk.
  actions: [create_brief]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# Session Prep Brief

Prepares a one-page brief before an upcoming client session. Not active
yet — calendar sources arrive in a later phase.

## Inputs

| Input | Where |
| --- | --- |
| The upcoming session event | named by the run |
| Client page and brief prompt | listed under `sources` above |

## Process

1. Read the client page: goals, open commitments, last session notes.
2. Write a one-page brief: where things stand, suggested focus, open loops.

## Outputs

One `proposal/v1` file at the exact path the run names. Do not send
anything.