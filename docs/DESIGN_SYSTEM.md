# Valea — Design System

**Source of truth:** "Paper & ink, with a green pen for approval." — Client-owned
AI admin cockpit, Design System V1 ([PDF](design/cockpit-design-system-v1.pdf),
received 2026-07-09). This file is the working transcription; where a pixel
value here disagrees with the PDF, the PDF wins.

> A warm, calm system for an app that handles someone's whole business. The
> palette does the safety talking: **green acts, amber suggests, terracotta
> warns.** Everything else is paper.

## 1. Principles

- **Calm, not a firehose.** Paper backgrounds, hairline borders, one accent at
  a time. No red badges except a true count of things waiting.
- **Color = consequence.** Green for safe, reversible actions. Amber for
  suggestions waiting on you. Terracotta only when something leaves the house
  (sends, deletes, charges).
- **Show the sources.** Every AI output carries source chips and a "why this"
  path. Monospace marks the file underneath — the ownership signature.
- **Plain language first.** "Approve — put in my Gmail drafts", never
  "Execute". Warm, brief, no exclamation marks. Technical detail is one toggle
  away, never the default.

## 2. Color

### Paper — surfaces

| Token | Hex | Use |
|---|---|---|
| canvas / desk | `#E9E3D6` | window canvas behind panes |
| app surface | `#FBF8F1` | main content background |
| card | `#FFFEFA` | cards, selected list rows |
| panel / rail | `#F7F2E7` | right rails, panels |
| sidebar | `#F3EEE2` | left sidebar |
| control track | `#EEE8D9` | segmented-control / pill tracks |
| status pill | `#ECE5D2` | status pill, ownership card |
| nav active | `#E7DFCA` | active nav item fill |
| tree active | `#EEE5CF` | ICM tree active row |
| border | `#E6DECB` | card borders |
| hairline / row | `#EFE9DA` | row separators |
| chip border | `#E0D7C1` | chips, tree guide line |
| button border | `#D8CFB9` | secondary button borders |

### Ink — text

| Token | Hex | Use |
|---|---|---|
| headings | `#29251E` | headings, emphasis |
| body | `#3D3B30` | body / email text |
| secondary | `#57503F` | secondary, nav idle |
| subtitle | `#6E6656` | subtitles |
| meta | `#948A75` | meta, timestamps |
| overline | `#A89085` | overlines, counts |

**Contrast floor:** `#948A75` is the lightest ink allowed on `#FBF8F1` for
meaningful text; `#A89085` only for overlines ≥ 700 weight and decorative
counts.

### Green — acts (safe, reversible)

| Token | Hex |
|---|---|
| primary action | `#2F5D48` |
| hover | `#244938` |
| badge tint | `#E6EDE2` |
| success / sync dot | `#2F8A5B` |

Use for: approve, open, review, booked calendar events, "reply drafted"
badges, links. **Never for anything that sends or deletes.**

### Amber — suggests (waiting on you)

| Token | Hex |
|---|---|
| amber ink | `#8F6E1F` |
| hold dash | `#C9A24B` |
| badge tint | `#F4E8D2` |
| suggestion bg | `#F9F2E3` |
| suggestion border | `#E8D9B5` |

Use for: memory updates, suggested additions, calendar holds, "update
suggested" badges, highlight marks in text.

### Terracotta — warns (irreversible)

| Token | Hex |
|---|---|
| warn ink, counts | `#B4512E` |
| email source dot | `#C0793F` |
| badge tint | `#F6E7DE` |
| card border | `#EBD5C6` |
| checkbox border | `#E0BDA9` |

Use for: "sends an email" badges, overdue counts, the "now" line on the
calendar, notification badge. **Outline buttons only — terracotta is never a
filled button.**

### Source-dot semantics

Dot color on source chips identifies the source type:

- Terracotta — email / external message
- Green — calendar / client memory
- Amber — policy / offer / document
- Green `#2F8A5B` — system OK / sync

## 3. Typography

Faces (via Google Fonts; bundle locally in the app — no runtime CDN):

- **Newsreader** — greetings, page titles, quoted memory. *The human voice.*
- **Instrument Sans** — all UI: labels, body, buttons, badges.
- **IBM Plex Mono** — file paths, YAML, "open the hood". *The ownership
  signature; never for friendly copy.*

Scale:

| Role | Spec |
|---|---|
| Greeting ("Good morning, Mara.") | Newsreader 500 · 32–40 |
| Page title ("Open loops") | Newsreader · 21–24 |
| Rail title ("Around your week") | Newsreader · 19 |
| Quote (verbatim source material) | italic · 14–15 |
| Card title | Instrument Sans 650 · 13.5–15 |
| Body copy | 13–14 · 400 · line-height ≥ 1.5 |
| Section overline | 10.5–12 · 700 · +0.09em tracking |
| File path / YAML | IBM Plex Mono · 10.5–12 |

**Voice:** address the user by first name. Say what was used and what happens
next. Buttons name outcomes: "Approve — put in my Gmail drafts", "Read, then
send…". No exclamation marks, no emoji, no jargon before the toggle. Body copy
explains what happened and what will happen next, in one or two sentences.

## Geometry

- Spacing on a **4px grid**; blocks step 8 → 12 → 16 → 20 → 32.
- Radii: 999px pills · 12px cards · 8–9px buttons · 7px list rows & events ·
  4px checkboxes.
- Shadows: cards `0 1px 2px rgba(42,38,32,.05)`; windows
  `0 24px 60px rgba(42,38,32,.28)`.

## 4. Buttons & actions

- **Primary (green fill)** — one per card, max. Safe & reversible only.
- **Secondary (outline)** — everything else: edit, snooze, dismiss.
- **Danger (terracotta outline)** — irreversible; the label names the
  consequence and ends in an ellipsis because a confirmation always follows
  ("Read, then send…"). Never filled, never the default focus.
- **Link action** — green 600, with a `→` for navigation ("Why this? →").
- **Segmented / filter pills** — 999px radius on the `#EEE8D9` track.
- Sizes: L 13px/8×16 · M 12px/6×12 · S 11.5px/3×9. Hit target ≥ 32px in dense
  lists, 36px+ elsewhere.

## 5. Badges, chips & pills

- **Kind badges** (what the AI did: REPLY DRAFTED, MEMORY UPDATE, SENDS AN
  EMAIL, PREP BRIEF, 2 HOLDS, ALWAYS ASKS FIRST, …) — 10–11px, 700, uppercase,
  +0.04em, 999px. Tint follows consequence: green = prepared/safe, amber =
  suggestion, terracotta = irreversible, neutral `#EEE8D9` = informational.
  Dashed border only for calendar holds.
- **Source chips** — always ≥ 1 on any AI output; dot color follows the
  source-dot semantics. Clickable → opens the source.
- **Count badges** — terracotta only in the main nav ("things waiting"); amber
  for suggestion counts; plain `#948A75` text for neutral counts.
- **Status pill** — one per screen, bottom of sidebar. Names the transport
  ("IMAP · Infomaniak") or "All local".

## 6. Cards — the approval family

Shared anatomy: kind badge → title → summary → source chips → actions. Border
`#E6DECB`, radius 12, padding 18×20, internal gap 10. "Why this?" always
bottom-right.

- **Approval card (safe)** — green primary button, e.g. "Approve draft".
- **Consequence card (sends something)** — terracotta border + badge, **no
  green fill anywhere** (the eye can't autopilot-approve). The consequence is
  stated in the body, in terracotta: "approving this sends the email — read it
  first." Actions like "Read, then send…" / "Wait a week".
- **Suggestion card (memory update)** — amber ground `#F9F2E3`, floats on any
  surface. Shows the change as a strikethrough diff (CHF ~~1,900~~ → **2,200**),
  names the target page, always Approve / Edit / Dismiss.

## 7. Navigation — sidebar & ICM tree

- Sidebar **236px**, `#F3EEE2`, three groups: **Daily** (Today, Mail, Calendar,
  Chat, Tasks), **Assistant** (Workflows, Knowledge + ICM tree, Files),
  **System** (Sources, Audit log). *(The PDF labels the ICM section "Memory";
  Valea ships "Knowledge" — product decision 2026-07-09.)*
- Item: 15px stroke icon (1.5px, round caps) + 13.5px label. Active =
  `#E7DFCA` fill, ink 600. Idle = `#57503F`. Hover = `#ECE5D2`.
- **ICM tree mirrors `icm/` exactly:** indented 17px behind a 1px `#E0D7C1`
  guide line, 12.5px rows, page counts right-aligned, amber count = pending
  suggestion inside. Tree active row uses the deeper `#EEE5CF`.
- Anchors, always: the status pill (one truth about where data lives) and the
  monospace `>_ Open the hood` as the very last row.

## 8. Lists & rows

- **Mail list item** — selected = `#FFFEFA` fill + 3px green left bar. Status
  badges show the assistant's work at a glance — never more than two.
- **Task row** — checkbox 15px / r4 / border `#C9BFA6` (terracotta `#E0BDA9`
  when the action sends). Provenance chip is mandatory. "Waiting on others"
  rows use a dashed circle · 0.85 opacity.
- **Dense queue / audit rows** — "done automatically" rows: green check, 0.75
  opacity, timestamp + Undo right-aligned. Never expandable-looking — they're
  receipts, not tasks.
- **Structured facts (memory page)** — label column `#948A75`, value 600 ink.
  Facts the assistant may quote verbatim live here, not in prose.

## 9. Calendar events & chat

Event vocabulary:

- **Solid fill + 3px green left bar = real** (booked session).
- **Dashed 1.5px border = the assistant's hand** — nothing dashed is ever
  committed. A hold converts to a booking only via an approval.
- Blocks (deep work) solid neutral; routines outlined; past events at 0.55
  opacity; the "now" line is terracotta.

Chat:

- User bubble: green fill, 14/14/4/14 radius. Assistant: card + border,
  mirrored radius, **source chips underneath every substantive answer**.
- Memory-update suggestion cards (§6) render inline in the thread, full width
  of the bubble column.

## 10. Panels, provenance & the hood

- **Rail cards ("why this draft")** — rails are 290–340px, `#F7F2E7`,
  Newsreader title. Each source gets its own card: dot-colored overline,
  italic serif quote (verbatim only), link to the origin.
- **Assistant strip (on a mail thread)** — one row per action: badge →
  sentence → link. Attach **under** the content it refers to, never above it —
  the human's material always comes first.
- **The hood — raw file preview** — progressive disclosure: friendly view
  default, raw one toggle away, YAML keys in amber. The ownership card
  (`#ECE5D2`: "This folder is yours — plain files… Export or hand it over
  anytime.") appears wherever files are visible.

## 11. Workflow timeline & layout grid

- Workflow steps: numbered ink circles (24px) on a 1.5px guide; **the final
  approval step is always the only green circle**. Each step pairs a friendly
  title with its monospace YAML reference right-aligned — the two layers of
  the same truth.
- **Layout grid:** sidebar 236 · optional list pane 250–340 · main flexible
  (content max 560–660) · optional rail 290–340.
- Page headers: overline date → Newsreader greeting/title → one-line subtitle.
  Section overlines separate content groups; **never boxed section headers.**

## Implementation notes (Valea-specific)

- Tokens land in `frontend/src/routes/layout.css` as the raw layer; shadcn
  semantic variables (`--background`, `--primary`, …) are mapped onto them so
  shadcn-svelte components inherit the paper/ink/green palette (legend's
  two-layer pattern).
- **shadcn-svelte is the component basis** (https://www.shadcn-svelte.com).
  The §11 layout grid maps to a reusable `AppShell` family: shadcn Sidebar
  (236px nav), an optional `ListPane` (250–340px — mail list, file browser,
  chat sessions; shadcn Resizable + Scroll Area + Item), flexible main, and an
  optional `Rail` (290–340px, `#F7F2E7`). Routes declare which columns they
  use; the panes are shared components, never per-feature layouts.
- The three consequence colors are first-class tokens (`--act`, `--suggest`,
  `--warn` families), not ad-hoc values in components.
- Fonts are bundled with the app (e.g. fontsource packages) — a local-first
  desktop app must not fetch fonts from a CDN at runtime.
- Light only; dark mode deferred (unchanged decision).
