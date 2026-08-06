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
counts. Dark mirrors the rule: `--ink-meta` on `--paper-surface` is the floor
for meaningful text there and measures 4.46:1 — better than light's 3.22:1 —
and `--ink-overline` stays restricted to ≥ 700-weight overlines and counts.
In both themes overline is QUIETER than meta; that ordering is what justifies
the weight restriction, and `frontend/src/lib/design/contrast.test.ts`
enforces the floor and the ordering against both palettes.

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
| warn ink, counts | `#AC4D2C` |
| email source dot | `#C0793F` |
| badge tint | `#F6E7DE` |
| card border | `#EBD5C6` |
| checkbox border | `#E0BDA9` |

Use for: "sends an email" badges, overdue counts, the "now" line on the
calendar, notification badge. **Outline buttons only — terracotta is never a
filled button.** Warn ink on the badge tint clears 4.5:1 in both palettes —
the overdue pill puts real text on that tint, and `contrast.test.ts` pins the
pair.

### Night paper — the dark palette

Dark is near-neutral with a faint warm cast, and lives in the `.dark` block in
`frontend/src/routes/layout.css` (canonical for these values). The elevation
chain keeps its direction — sorted by luminance, `canvas` → `track` →
`sidebar` → `panel` → `surface` → `card` ascends in both themes, so "lifted
onto card paper" means the same thing at night. The interaction fills (`pill`,
`nav-active`, `tree-active`) legitimately run the other way: you darken cream
paper and lighten dark paper to pick a row out.

Paper:

| Token | Light | Dark |
|---|---|---|
| `--paper-canvas` | `#e9e3d6` | `#121211` |
| `--paper-track` | `#eee8d9` | `#151413` |
| `--paper-sidebar` | `#f3eee2` | `#171615` |
| `--paper-panel` | `#f7f2e7` | `#191817` |
| `--paper-surface` | `#fbf8f1` | `#1b1a19` |
| `--paper-card` | `#fffefa` | `#232321` |
| `--paper-pill` | `#ece5d2` | `#282726` |
| `--paper-nav-active` | `#e7dfca` | `#2e2d2b` |
| `--paper-tree-active` | `#eee5cf` | `#32312e` |
| `--paper-hairline` | `#efe9da` | `#222220` |
| `--paper-border` | `#e6decb` | `#2f2e2d` |
| `--paper-chip-border` | `#e0d7c1` | `#383735` |
| `--paper-button-border` | `#d8cfb9` | `#444341` |

Ink:

| Token | Light | Dark |
|---|---|---|
| `--ink-heading` | `#29251e` | `#e9e8e6` |
| `--ink-body` | `#3d3b30` | `#d2d0ce` |
| `--ink-secondary` | `#57503f` | `#b6b5b2` |
| `--ink-subtitle` | `#6e6656` | `#9f9e9b` |
| `--ink-meta` | `#948a75` | `#83817f` |
| `--ink-overline` | `#a89085` | `#807d7b` |

Consequence colours keep their meanings. `--act-hover` goes **lighter** than
`--act` in dark where light darkens it — hover means "more", and on dark paper
more is lighter (its exact value is capped so `--primary-foreground` on the
hover fill still clears 4.5:1; the derivation lives with the token):

| Token | Light | Dark |
|---|---|---|
| `--act` | `#2f5d48` | `#2f7a57` |
| `--act-hover` | `#244938` | `#2a8354` |
| `--act-tint` | `#e6ede2` | `#1c2a22` |
| `--act-dot` | `#2f8a5b` | `#4fa97a` |
| `--suggest-ink` | `#8f6e1f` | `#d3ac5f` |
| `--suggest-dash` | `#c9a24b` | `#a8873f` |
| `--suggest-tint` | `#f4e8d2` | `#2e2616` |
| `--suggest-bg` | `#f9f2e3` | `#26200f` |
| `--suggest-border` | `#e8d9b5` | `#3d3320` |
| `--work-dot` | `#4a7dab` | `#6b9dc9` |
| `--warn-ink` | `#ac4d2c` | `#e08a5f` |
| `--warn-dot` | `#c0793f` | `#d08055` |
| `--warn-tint` | `#f6e7de` | `#2e1d15` |
| `--warn-border` | `#ebd5c6` | `#4a2f22` |
| `--warn-checkbox` | `#e0bda9` | `#5c3a29` |

Avatar fills — four distinguishable identity colours, each carrying
`--primary-foreground` at ≥ 4.5:1 in both themes. Deliberately not the
consequence palette: an avatar means "which account", not "safe / suggests /
warns":

| Token | Light | Dark |
|---|---|---|
| `--avatar-fill-1` | `#2f5d48` | `#2f7a57` |
| `--avatar-fill-2` | `#8a4a2f` | `#a85c3a` |
| `--avatar-fill-3` | `#6b4b8a` | `#8460a8` |
| `--avatar-fill-4` | `#2f5470` | `#3a6a8f` |

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
| Memory page title ("Founder Coaching") | Newsreader 500 · 30 |
| List-pane title ("Mail", "Chat") | Newsreader 500 · 21 |
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

### Tasks board

The board's vocabulary, shared with the task list so a card and a row say the
same things (redesign 2026-08-06):

- **Status columns** — Open · In progress · Done, always in that order. A
  status Valea doesn't know gets its own column at the end, labelled with the
  raw string **verbatim** and drawn with a **dashed** border: same affordances,
  visibly yours rather than ours. Dropped entries get no column.
- **Overdue pill** — `--warn-tint` fill, `--warn-ink` text, `--warn-border`
  border; the one filled chip in the row, because overdue is the only state
  that earns reading from across the page. The pair is pinned at 4.5:1 in both
  palettes (§2, Terracotta).
- **Priority glyphs** — `‼` high · `!` medium · `·` low, in a fixed 4-unit
  column so a scan reads the rank without the word eating title width. An
  unknown priority renders no glyph and keeps its verbatim text chip.
- **⚙** — assigned to the assistant. Who *works* the task, not who created it.
- **Done cards and rows are receipts** (§8): dimmed, struck through, green
  check — never expandable-looking.

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

- **List-pane header** — Newsreader 21 pane title with a secondary action
  right-aligned on the same row; optional filter-pill row underneath (999px
  pills, the active one filled on the `#EEE8D9` track, idle ones plain
  `#57503F` text); a hairline separates the header block from the rows.
- **Mail list item** — selected = `#FFFEFA` fill + 3px green left bar. Status
  badges show the assistant's work at a glance — never more than two. Sender
  line 650 with the relative time right-aligned, subject under it, hairline
  row separators.
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
- **Composer** — a bordered `#E6DECB` card (radius 14, card paper, card
  shadow) floating on the surface, docked at the pane's bottom edge with the
  transcript scrolling above it; the send button sits inside the card,
  bottom-right. Session config selectors (model, mode, …) render as a quiet
  12px text-plus-chevron row *below* the card, never as chips inside it.

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
  (content max 560–660) · optional rail 290–340. Today: main 880 + rail 300
  (folds under a 1212px **container** width — the pane's own width, via
  `@container` / `@min-[1212px]`, not the viewport's, so the rail keeps its
  room when the sidebar collapses instead of folding on a viewport number that
  no longer describes the space it has).
- Page headers: overline date → Newsreader greeting/title → one-line subtitle.
  Section overlines separate content groups; **never boxed section headers.**

## Implementation notes (Valea-specific)

- Tokens land in `frontend/src/routes/layout.css` as the raw layer; shadcn
  semantic variables (`--background`, `--primary`, …) are mapped onto them so
  shadcn-svelte components inherit the paper/ink/green palette (legend's
  two-layer pattern).
- **shadcn-svelte is the component basis** (https://www.shadcn-svelte.com).
  The §11 layout grid maps to a reusable `AppShell` family: shadcn Sidebar
  (236px nav, collapsible) beside a content column holding the route's pane
  row and the content bar. The rail column is gone and the `list` column with
  it — composable views made each pane carry its own navigator, so `ListPane`
  (250–340px; shadcn Resizable + Scroll Area + Item) is now a component a
  ROUTE renders inside its own main slot rather than a column the shell owns.
  The panes are shared components, never per-feature layouts.
- The three consequence colors are first-class tokens (`--act`, `--suggest`,
  `--warn` families), not ad-hoc values in components.
- Shared shell primitives — one implementation each, never re-rolled per
  view: `ListPane` (pane title + action + filter row), `PageHeader` (§11
  main-pane header), `SegmentedControl` (view toggles), `FilterPill` (list
  filters), `EmptyState`. (§10's `RailCard` went with the rail column.) Empty states grow a
  small procedural garden (`PlantGrowth`) — decorative only, `aria-hidden`,
  fully static under `prefers-reduced-motion`.
- Fonts are bundled with the app (e.g. fontsource packages) — a local-first
  desktop app must not fetch fonts from a CDN at runtime.
- **Colour reaches components through tokens, never literals — and a token is
  chosen for its ROLE, not its appearance.** Ink on a consequence fill is
  `--primary-foreground`, never `--paper-card`: in light they are the same
  value, so the mistake is invisible until a second palette exists. Surfaces
  are `--paper-*`, ink is `--ink-*`, and neither substitutes for the other.
- Light and dark. Dark is "night paper" — near-neutral with a faint warm cast — and lives
  in the `.dark` block in `layout.css`. The elevation chain keeps its
  direction in both themes; `--ink-overline` stays quieter than `--ink-meta`
  in both. `frontend/src/lib/design/contrast.test.ts` enforces both, plus the
  §2 contrast floor, against both palettes.
