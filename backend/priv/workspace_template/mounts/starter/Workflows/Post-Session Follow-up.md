---
enabled: false
trigger: { type: manual, source: calendar.completed }
sources:
  - { id: completed_event, type: calendar, required: true }
  - { id: client_page, type: icm, path: "Clients/*" }
  - { id: tone_guide, type: icm, path: "Tone & Voice/Email Tone Guide.md" }
  - { id: followup_template, type: icm, path: "Templates/Follow-up Email.md" }
risk_level: medium
approval:
  required: true
  reason: Email replies must be reviewed before sending.
  actions: [create_email_draft]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---
# Post-Session Follow-up

Drafts a follow-up email after a completed client session. Not active yet — calendar sources arrive in a later phase.

## Inputs

| Input | Where |
| --- | --- |
| The completed session event | named by the run |
| Client page, tone guide, template | listed under `sources` above |

## Process

1. Summarize what was discussed and any commitments made.
2. Draft a warm follow-up email using the tone guide and the client's open commitments.

## Outputs

One `proposal/v1` file at the exact path the run names, with `kind: "email_draft"`. Do not send anything.