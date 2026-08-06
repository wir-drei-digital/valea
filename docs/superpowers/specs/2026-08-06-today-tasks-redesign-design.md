# Today & Tasks redesign — design

**Status:** Approved (brainstorm 2026-08-06; mockup rounds 1–5 on the review artifact)
**Scope:** Today page, Tasks page (list + new board view), small Schedules-tab fixes, one backend cockpit change.

## Problem

Both pages waste a large desktop (660px column in a ~1500px pane) and read
alpha. Structurally worse: the Today page hides real work — `Valea.Cockpit`
drops an ICM's section when `today.json` is absent, and the per-ICM tasks line
lives inside that section, so a workspace with 34 open tasks (6 high-priority)
renders "Nothing prepared yet" and zero tasks. The Tasks page's default Today
filter is empty whenever nothing is due, every row repeats the same three
chips, and the deepest interaction is a 7-field modal with a one-item overflow
menu. Full critique in the session; what follows is the agreed design.

## Decisions (from the brainstorm)

- Today is an **actionable cockpit**: tasks, agenda, and attention items are
  first-class regardless of `today.json`; the agent's briefing is one section.
- Layout: **editorial column + rail** (A) with **card containment** (B) where
  a box earns its keep — attention interrupt, agent briefing, rail modules.
- Task features: **hand to assistant**, **day planning**, **search + sort +
  grouping**, **board view with status columns** (defaults + custom statuses
  from the file). Keyboard-navigation/inline-edit models were considered and
  not selected.
- Overdue tasks get **prominent treatment**: own warn-colored group, filled
  warn pill, warn count in the summary line.
- Filter settings **persist** (localStorage, the `valea.theme` precedent).

---

## Part 1 — Today page

### Layout

`AppShell` + `Sidebar` as today. The main area becomes a two-region grid
inside the scrolling column: main column `minmax(0, 880px)` + right rail
`300px`, `gap 32px`, the pair centered. Below `1180px` viewport width the
rail folds under the main column (single column, rail cards full-width).
Dark mode uses existing tokens throughout; no new tokens.

### Header

- Overline: full local date — `WEDNESDAY, AUGUST 6` (§11's "overline date").
- Greeting: `Good morning` / `Good afternoon` / `Good evening` by local hour
  (5–12 / 12–18 / else), Newsreader display ~28px. No user name exists in the
  product; the greeting stays impersonal.
- Summary line (13px, `ink-meta`): parts joined by ` · `, zero-valued parts
  dropped, whole line hidden when all parts drop:
  - `N tasks for today` — count after the assignee toggle, overdue included
  - `M overdue` — **warn ink**, only when M > 0
  - `K things need your attention` (`1 thing needs…`) — attention-card rows
  - `next event HH:MM` — first agenda event starting at/after now
- The old per-account `account: state · n pending` lines and `0 events today`
  line are **deleted**. Mail state lives on the rail's mail card.

### Composer

Same quick-start flow, slimmer visual (single-row height), plus an **ICM
picker** (`NativeSelect`, borderless chip look) inside the composer's left
edge. Default = MRU mount (`mostRecentMountKey`, as today); an explicit pick
lasts for the visit (not persisted — MRU wins again next load). Placeholder:
`Start a session…` (the picker already names the target).

### Needs attention (card)

One tinted card (`warn-tint` bg, `warn-border` border, rounded-xl) directly
under the composer. Rows:

- Git attention rows (`gitStore.attentionRepos`) with their existing
  `Resolve with agent` / `Open session` buttons and error lines — behavior
  unchanged, only re-homed.
- Schedule notices of kind `waiting` and `failed`, linking to
  `/tasks?tab=schedules` as today. (`registered` notices move to the rail's
  Schedules card — they're FYI, not interrupts.)

Card renders only when it has rows.

### From your agent (cards)

For each enabled ICM, keyed off the cockpit section's new `today_json` state:

- `present`: a card (`paper-card` bg, `paper-border`) with overline
  `FROM YOUR AGENT · <icm name> · updated <stamp>`, the `notes` text, and the
  `prepared` list (title → knowledge link when `page` is set, summary below).
- `unreadable`: the calm one-line note (`today.json couldn't be read`), no card.
- `absent`: nothing — no placeholder box.

Cards stack (workspace order) below Needs attention, above tasks.

### Today's tasks

Rendered from the task ledgers via `tasksStore` (the Tasks page's store),
**not** from the cockpit payload — Today gains live mutations for free
(checkbox completes a task in place; row click opens the shared `TaskEditor`
dialog). `icm_changed` refresh wiring as on the Tasks route.

- Base set: the existing `todayFilter` (due today + overdue + `today` flag +
  `in_progress`), merged across ICMs, standard sort.
- **Assignee toggle** in the section header: `Mine · Everyone`
  (SegmentedControl, small variant). `Mine` = `(assignee ?? 'user') === 'user'`.
  Persisted under its own key, `valea.today.assignee` (Part 2 → Persistence).
  Header count reads `2 of 3 tasks` when the toggle hides rows.
- **Overdue group first**: its own subsection under a warn-ink overline
  `OVERDUE · n`, sorted oldest due first. Then the `TODAY` subsection with
  the rest. Overdue rows carry the overdue pill (Part 3).
- Row: checkbox (32px target / 15px visual) · title · due-or-overdue chip ·
  priority glyph · project tag. Row click → editor dialog.
- Tail line: `N more in the backlog · k with the assistant · Plan today →`,
  linking to `/tasks`. `N` counts open tasks outside the today view under the
  current toggle; `k` counts assistant-assigned today-view tasks hidden by
  `Mine` (part dropped when zero) — the toggle never silently lies.

### Agenda

Shown only when the cockpit `calendar` summary is non-null (the "calendar
subsystem has something to say" signal). Events fetched via the existing
`listCalendarEvents` RPC for the local-day range. Rows: `HH:MM` (tabular) ·
title · duration chip when an end time exists. Configured-but-empty day:
one quiet line `No events today.`

### Rail

Three quiet cards (`paper-card` bg), each rendered only with content:

1. **New mail** — newest unread rows across configured accounts (cap 4:
   sender-or-subject line, deep link to `/mail?account=…&message=…`), then one
   footer line per configured account: `<account> · <n> unread → open Mail`.
2. **Schedules** — `registered` notices from the last 24h, linking to the
   Schedules tab. (Planning amendment: the mocked `next: <title>, <time>`
   line is cut — no next-fire time exists on the frontend wire, and adding
   a scheduler API for a rail garnish fails YAGNI. Revisit if the tab ever
   grows next-run display.)
3. **Recent sessions** — up to 5, as today (live dot, timestamp).

### Empty page

When there is nothing at all (no attention, no agent cards, no tasks, no
agenda, empty rail): one compact welcome card in plain language — each
project keeps a shared task list you and the assistant both work from; the
assistant can also prepare a morning briefing per project ("ask it to
maintain one"). No file-name code literals on this surface.

### Backend change (the one)

`Valea.Cockpit.icm_section/1` emits a section for **every** enabled
`kind: :icm` mount:

- New field `"today_json" => "present" | "absent" | "unreadable"`; the `"ok"`
  boolean is retired. `absent` sections carry the empty briefing fields.
- The tasks line stays computed per-section exactly as now (the redesigned
  page reads ledgers via `list_tasks`, but the cockpit line remains the
  cheap summary for any consumer and its tests stand).

Frontend `normalizeCockpitToday` follows (state string, both key spellings,
unknown value degrades to `unreadable` — never a crash).

---

## Part 2 — Tasks page

### Frame

`PageHeader` stays; subtitle shortens to one clause (`You and the assistant
share these lists — plain files in your project folders.`). Content cap
widens to ~1100px for the list; the board uses the full pane width with the
standard gutter. Tab structure (Tasks | Schedules) unchanged.

### Controls row

One row under the header, left to right:

- **List | Board** toggle (SegmentedControl).
- **Today · n | All · m** — counts computed over the current assignee filter
  but ignoring search text (a segment never promises rows its click won't
  show; search is transient narrowing, not a view).
- **Mine | Assistant's | Everyone** assignee filter (`user` / `agent` / null).
- **Group** select (list only): `project` (default) · `priority` · `due`.
- **Search** input (right-aligned): case-insensitive substring over title +
  notes, applied within the current view + filters, debounced ~150ms.
  Empty result: `No tasks match "q".`
- The status SegmentedControl (`Any status / In progress / Done`) is
  **removed** — the board covers status browsing; done rows fold (below).

### Persistence

One guarded-localStorage JSON key `valea.tasks.filters`:
`{ mode: 'list'|'board', view: 'today'|'all', assignee: 'user'|'agent'|null,
groupBy: 'project'|'priority'|'due' }`, plus `valea.today.assignee` for the
Today page toggle. A tiny shared helper (`lib/persist.ts`) wraps the
guarded read/write pattern from `theme.svelte.ts` (try/catch is the guard —
Node 25 defines `localStorage` with undefined methods); malformed or unknown
stored values degrade field-wise to defaults. Search text and "Show done"
expansions are session-local, never persisted.

### List rows (density pass)

Single-line row: checkbox · priority glyph · title (truncating, click →
editor) · assistant marker · source chip · due/overdue chip · session chip ·
hover/focus actions. Specifics:

- **Priority glyph** replaces the word: `‼` high (warn-ink) / `!` medium
  (`--warn-dot` amber) / `·` low (`ink-meta`) / blank none. Unknown priority
  values render as their verbatim text chip (leniency).
- **Assistant marker**: the uppercase `FROM ASSISTANT` badge is retired.
  Assistant-**assigned** rows get a small `⚙` glyph with tooltip/aria
  `assigned to the assistant`. (Creator provenance stays visible in the
  editor; it stopped earning row space.)
- **Source chip** shrinks to the locator's basename (`CONTEXT.md`), same
  link/plain-text logic as today, `max-w` truncation.
- **Session chip**: when the task carries a `session` key (set by hand-off),
  a small chip `session` linking `/chat?session=<id>`, with the live dot
  when that session is live per `recentSessionsStore`.
- **Hover/focus actions** (visible on row hover, focus-within, and always in
  the `⋯` menu for keyboard/touch): `→ Assistant` (hand-off), `Today` /
  `Today ✓` (toggle the `today` flag), `⋯` menu (Edit, Drop). The checkbox
  stays the complete/reopen control.
- Done/dropped rows **fold** per group behind a footer line
  `n done · Show · Clear done` (`Show` toggles session-local visibility;
  `Clear done` keeps its inline count-naming confirmation). Groups with zero
  open and zero done rows don't render; the whole-view empty message stays
  singular.
- **Quick add** becomes the list's first row (`+ Add a task…` input ·
  project picker · implicit `today: true` while the Today view is active —
  existing behavior preserved).

### Day planning

- The `Today` row action is the planning primitive: one click pulls a task
  into today / drops it out (patches the `today` flag).
- **Empty Today view is never blank**: it renders `Next up` — the top 5
  backlog rows by standard sort, each with a `Today` button — plus the
  existing "All shows the whole backlog" line.

### Group-by buckets

- `project`: current per-ICM sections (name, open count, Clear done footer).
- `priority`: High / Medium / Low / None buckets (unknown priorities join
  None, chip shown).
- `due`: Overdue / Today / This week / Later / No date, computed off
  `todayIso` string comparison (host zone, the `localDateIso` rules).
Within every grouping, overdue rows sort first (due ascending already does
this); the pill provides the visual signal.

### Hand to assistant (`→ Assistant`)

Uses only existing primitives (the Today quick-composer flow):

1. `createAgentSession(mountKey, generation)`.
2. `setInitialPrompt(sessionId, prompt)` — prompt composed from the task:
   title, notes, due, priority, source locator, task id, plus the standing
   instruction that the agent works the task and updates its entry (status,
   notes) in `tasks.json` — `.valea/briefing.md` already teaches the ledger
   contract; the prompt names the task id and file so the session starts
   anchored.
3. `patchTask` → `{ status: 'in_progress', assignee: 'agent',
   session: <sessionId> }` (the leniency contract round-trips the new
   `session` key untouched).
4. Navigate to `/chat?session=<id>` — the initial prompt is consumed by the
   chat view (its existing contract), so the session starts working
   immediately; the task row's session chip is the way back.

Failure at step 1/2 surfaces the existing harness-hint copy inline; failure
at step 3 (rare: session exists, patch failed) surfaces `taskErrorMessage`
and does not navigate, leaving the session reachable from Recent sessions.
Per-row busy state disables the action while in flight; id-less tasks (no
`id`) don't offer the action (repair affordance first, as today).

### Board view

- **Columns**: `Open` · `In progress` · `Done` always, in that order; then
  one column per additional distinct status found in the filtered data
  (first-seen order, dashed header, label = verbatim status text). The
  design anticipates custom statuses; the default set stays these three.
  `dropped` entries never get a column — they live behind Clear done.
  `""` (no status) renders in Open (matches the resting-state reading).
- **Cards**: title (2-line clamp) · priority glyph · `⚙` marker · due or
  overdue pill · project tag · session chip. Click → editor dialog.
  Id-less entries render as inert cards with the repair note.
- **Drag** (native HTML5 DnD, no library): dropping a card on a column
  patches `status` to that column's value — including custom columns
  (verbatim string; `patchTask`, not `setTaskStatus`). Optimistic move,
  revert + error line on failure. Keyboard/touch fallback: the editor's
  status select (already exists).
- Done column footer: `Archive all` → inline confirmation naming per-project
  counts → `clearDone` per mount, sequentially; partial failure reports the
  failing project and stops.
- Quick add row stays above the board (adds to Open).
- Group-by is a list concept; the board is status-grouped by definition.
  Search, Today|All, and assignee filters all apply to the cards shown.

### Schedules tab (small fixes only)

- `New schedule` moves above the kill switch.
- The kill-switch block moves to the bottom as a quiet footer row and
  renders only when at least one schedule exists.
- Empty per-ICM sections collapse into one `No schedules yet` line.

---

## Part 3 — Shared pieces

- **`OverduePill`**: filled pill, `warn-tint` bg, `warn-border` border,
  `warn-ink` text, 600 weight, text `n day(s) over` (from `todayIso` minus
  `due`, string-date math in the host zone). Used by Today, list, board.
  Titles stay ink — urgency is flagged without turning rows red.
- **`PriorityGlyph`**: the ‼/!/· component above.
- **`RailCard`** and the Today section components (`AttentionCard`,
  `AgentBriefingCard`, `TodayTasks`, `AgendaSection`) live under
  `lib/components/today/`; board pieces (`TaskBoard`, `BoardColumn`,
  `TaskCard`) under `lib/components/tasks/`. Pure decisions live in tested
  modules: `lib/today/greeting.ts` (greeting + summary line),
  `lib/tasks/board.ts` (column derivation), `lib/tasks/filters.ts` grows
  group-by buckets, search, overdue-days; `lib/tasks/handoff.ts` (prompt
  composition); `lib/persist.ts` (guarded storage).
- **Contrast invariant addition**: `warn-ink` on `warn-tint` ≥ 4.5:1, both
  palettes, pinned in `contrast.test.ts` (the pill makes this pair
  load-bearing for the first time).

## Error handling

Unchanged leniency contract everywhere: unreadable ledgers stay calm notes,
unknown statuses/priorities render verbatim, per-ledger failures scope to
their section, a failed background cockpit refresh keeps the last good
payload. New surfaces follow: a failed agenda fetch shows a one-line
`Couldn't read today's events` with retry (the section is hidden only when
the cockpit says calendar has nothing to say), board drag failures revert
visibly, hand-off failures never leave a half-linked task silently (see
flow above).

## Testing

- **Unit (vitest)**: greeting/summary-line composition (hour and part-drop
  cases); overdue grouping + pill day-math (incl. month boundaries, TZ via
  string dates); board column derivation (defaults, custom statuses,
  first-seen order, dropped/`""` handling); group-by buckets; search
  predicate; `persist.ts` (guarded, malformed JSON → defaults, unknown enum
  values dropped field-wise); hand-off prompt composition; cockpit
  normalizer `today_json` states.
- **Runes tests**: persisted-filter store behavior; Today assignee-toggle
  count honesty ("2 of 3").
- **Backend (ExUnit)**: `icm_sections` emits absent/present/unreadable
  states for every enabled ICM; rpc test pins updated (sections no longer
  vanish with the file).
- **Updated**: TasksTab tests (removed status control, folding, next-up),
  existing cockpit/rpc pins, `contrast.test.ts` new invariant.

## Out of scope

Keyboard navigation (j/k/x), inline due/priority editing on the row, snooze
presets, session-title quality (rail shows what titling produces), mail and
calendar page changes, notifications, any change to schedule execution or
consent, Windows-specific work.
