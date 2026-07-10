---
enabled: true
trigger: { type: manual, source: email.selected }
sources:
  - { id: current_email, type: email, required: true }
  - { id: founder_coaching_offer, type: icm, path: "icm/Offers/Founder Coaching Package.md" }
  - { id: tone_guide, type: icm, path: "icm/Tone & Voice/Email Tone Guide.md" }
  - { id: no_medical_advice, type: icm, path: "icm/Policies/No Medical Advice.md" }
  - { id: pricing, type: icm, path: "icm/Pricing/Current Pricing.md" }
risk_level: medium
approval:
  required: true
  reason: Email replies must be reviewed before sending.
  actions: [create_email_draft]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---
# New Inquiry Triage

Classifies a new email inquiry and drafts a reply for review.

## Inputs

| Input | Where |
| --- | --- |
| The inquiry email | named by the run |
| Offer, tone, policy and pricing pages | listed under `sources` above |

## Process

1. Summarize the incoming inquiry in two sentences.
2. Classify it: good-fit, unclear, not fit, or spam.
3. Draft a warm reply using the tone guide and the relevant offer. Respect the no-medical-advice policy.

## Outputs

One `proposal/v1` file at the exact path the run names, with `kind: "email_draft"`. Do not send anything.