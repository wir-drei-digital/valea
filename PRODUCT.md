# Product

## Register

product

## Users

Solopreneurs — first avatar: an independent coach (seed persona: Mara Lindt,
Mara Lindt Coaching) whose day runs on client inquiries, scheduling, session
prep, follow-ups, invoices, and a weekly admin review. They are not technical;
they open the app each morning to understand the day, review AI-prepared work,
and approve or reject it. Trust is the scarce resource.

## Product Purpose

Valea is a local-first agentic operating system for solopreneurs: a desktop
cockpit (Tauri + SvelteKit + Phoenix sidecar) combining mail, calendar, chat
assistant, tasks, and file-backed business memory (ICM). The AI prepares admin
work transparently and waits for human approval before anything consequential.
Success: the user reviews prepared work each morning and trusts the system
enough to keep teaching it. Full vision: docs/VISION.md.

## Brand Personality

Calm, trustworthy, warm. "Paper & ink, with a green pen for approval." Plain
language first, technical detail one toggle away. Address the user by first
name; buttons name outcomes ("Approve — put in my Gmail drafts"). No
exclamation marks, no emoji in product copy.

## Anti-references

- Hype AI aesthetics: glowing gradients, sparkle icons, "magic" language.
- Vanity-metric dashboards and hero-number templates.
- Black-box automation UI — every output must show sources ("Why this?").
- Cold enterprise admin panels (dense gray tables, blue-link chrome).

## Design Principles

1. Color = consequence: green acts, amber suggests, terracotta warns —
   everything else is paper. (Canonical spec: docs/DESIGN_SYSTEM.md.)
2. Calm, not a firehose: paper surfaces, hairline borders, one accent at a
   time.
3. Show the sources: source chips + monospace file paths are the ownership
   signature.
4. The human's material comes first; assistant annotations attach underneath.
5. Nothing dashed is ever committed; nothing irreversible is one click away.

## Accessibility & Inclusion

Light theme only (dark deferred — standing decision). Contrast floor: `#948A75`
is the lightest ink on `#FBF8F1` for meaningful text. Hit targets ≥ 32px in
dense lists, 36px elsewhere. Reduced-motion alternatives for all animation.
Fonts bundled locally (Newsreader, Instrument Sans, IBM Plex Mono) — no runtime
CDN.

## Visual System

docs/DESIGN_SYSTEM.md is the working transcription of the canonical Design
System V1 PDF (docs/design/cockpit-design-system-v1.pdf). Where they disagree,
the PDF wins. Tokens live in frontend/src/routes/layout.css; shadcn-svelte
semantic variables map onto them.
