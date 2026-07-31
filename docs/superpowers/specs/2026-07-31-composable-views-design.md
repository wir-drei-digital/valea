# Composable Views — Multi-Pane Content Area

**Date:** 2026-07-31
**Status:** Design. Supersedes the single-pane half of
`2026-07-28-side-panes-design.md` (that spec's codec, registry and pane
chrome all survive; only the "exactly one side pane" constraint is lifted).

## Goal

On a large screen Valea wastes most of its width. The content area shows one
view; the ICM file tree is either a route's list column (`/knowledge`) or a
popover buried in the chat header; and a file opened from a tool chip takes
the single side-pane slot, so you can never have the file browser, the
transcript and the file itself on screen together.

This spec makes the content area composable **without introducing a layout
system**. It extends the mechanism already shipped — the route's primary view
plus a side pane — from one pane to two, gives Mail and Knowledge the same
`PaneHost` Chat already has, and puts the two controls that drive it on a
quiet bar along the bottom of the content area.

The explicit non-goal is a tiling window manager. Valea's user is a
non-technical solopreneur; the feature has to be legible on first sight and
impossible to get lost in. One concept — *"there is the view you are on, and
you can open things beside it"* — extended, not replaced.

## Decisions settled with Daniel (2026-07-31)

- **Build on the split pane, not on docks.** An earlier draft proposed
  Zed-style slots (left/right/center), a panel registry addressable per slot,
  per-center layout memory and a six-chip toggle bar. Rejected as *"almost too
  composable, which will confuse regular users"* — it invents a vocabulary the
  user must learn before it pays off. The vocabulary here is the one that
  already exists.
- **Two panes beside the primary, hard cap.** Three content columns at most.
  The cap is the thing that keeps this from becoming a tiling manager.
- **The file tree is not a pane.** It stays a narrow, fixed-width column at
  the existing list-column width, toggleable on any pane-host route. It must
  never widen to pane proportions.
- **Mail is a pane host too**, so a message can have a chat beside it — the
  case that made this app-level rather than a chat feature.
- **Controls go on a bottom bar inside the content container.** The left nav
  is a full-height fixed anchor; the bar sits *beside* it, not under it.
- **Panes are remembered per route.** Leaving chat and coming back restores
  what you had beside it. A URL that names panes always wins over memory.

## Layout

```
┌────────┬──────────────────────────────────────────────────┐
│        │ ┌────────┬──────────────┬──────────┬───────────┐ │
│        │ │ Files  │  Chat        │ AGENTS.md│  Mail     │ │
│  Nav   │ │        │  (primary)   │ (pane 1) │ (pane 2)  │ │
│  236   │ │  300   │              │          │           │ │
│ (full  │ │ fixed  │  flexible    │ flexible │ flexible  │ │
│ height)│ └────────┴──────────────┴──────────┴───────────┘ │
│        │ ▣ Files  ▢ Sessions                    ＋ Pane   │
└────────┴──────────────────────────────────────────────────┘
```

`AppShell` restructures to make the nav a genuine anchor and the bar a
property of the content area:

```svelte
<div class="flex h-screen">
  <aside class="w-[236px] shrink-0 …">{@render nav()}</aside>
  <div class="flex min-w-0 flex-1 flex-col">
    <div class="flex min-h-0 flex-1">
      {#if column}<section class="w-[300px] shrink-0 …">…</section>{/if}
      <PaneHost … />
    </div>
    <ContentBar … />
  </div>
</div>
```

Widths follow `DESIGN_SYSTEM.md` §11 unchanged: nav 236 · narrow column fixed
at 300 (the band is 250–340) · primary and panes flexible. The column is not
resizable — that is what keeps the tree from ever reaching pane proportions.
Minimum widths are primary 380px and 300px per pane; `PaneResizer` divides the
flexible remainder, as today.

### The narrow column

One column, one occupant, chosen per route. The occupants are the route's
existing list panes plus the ICM tree:

| Route | Offers | Default |
|---|---|---|
| `/chat` | Files · Sessions | none |
| `/mail` | Mail list · Files | Mail list |
| `/knowledge`, `/knowledge/[...path]` | Files | Files |

Behaviour is radio, not checkbox: turning one on turns the other off, and
clicking the active one closes the column. Explaining it takes one sentence —
*"one narrow column; pick what goes in it."*

This retires the popover file tree in `SessionHeader.svelte` (its
`Popover.Root` wrapping `IcmTree`, and the `treeRequestedFor` root-load effect
in `ChatView` that feeds it). The tree becomes one component in one place,
rendered from `IcmTree` exactly as Knowledge renders it today.

The **file-activity rail** is untouched. It is a separate shipped feature
(`2026-07-30-session-file-activity-design.md`), it lives inside `ChatView`
rather than in a shell slot, and its `railCanShow` gate already measures
`ChatView`'s own container — so opening panes shrinks the chat and the rail
falls back to its header pill on its own, with no new rule. `filesPopover` is
that fallback, not a file browser, and stays.

### Panes

Unchanged from `2026-07-28-side-panes-design.md` except for count. Each pane
keeps its chrome — title · promote (⤢) · close (✕) — its registry-driven
component, and `promoteHref`. Pane kinds:

| Kind | Wire form | Status |
|---|---|---|
| file | `file:<mountKey>/<relPath>` | exists |
| chat | `chat:<sessionId>` | exists |
| chat-new | `chat:new:<mountKey>` | exists |
| mail | `mail:<messageId>` | **new** |

## URL scheme

**Panes repeat the existing `pane` param** rather than introducing a new
delimited one:

```
/chat?session=a91f&pane=file:life/AGENTS.md&pane=mail:8842
```

This is deliberate and buys back-compatibility for free: a single `?pane=` —
every link, bookmark and restored session in the wild today — parses as a
one-element list with no special case. Document order is left-to-right pane
order. A third `pane` param is dropped on parse, so a hand-written URL cannot
exceed the cap.

**The narrow column is `?col=`:** `files`, `sessions`, `mail-list`, or `none`
(`mail-list`, not `mail`, so a column value is never confusable with the
`mail:` pane kind).
Absent means the route's default, so `/mail` still opens with its list and
`/chat` still opens bare. `none` is what lets you express "mail with its list
closed" in a URL. Chat's existing `?all=1` maps to `?col=sessions` and is
kept as a parse-time alias.

The URL remains the single source of truth for what is on screen, which is
what keeps a composition linkable, reload-proof, and closable with the back
button — the property `pane-route.ts` was built around and the reason none of
this lives in component state.

## Memory

`localStorage`, one entry per route key:

```
valea.content.<routeKey> → { panes: string[], col: string | null }
```

Written on every pane/column change. Applied **only when the URL names
neither** — entering `/chat` bare restores your last composition via
`goto(…, { replaceState: true })`, so the URL immediately becomes explicit and
the back button behaves. A URL that carries `pane` or `col` always wins, so a
link shared between two people never gets rewritten by the recipient's habits.

Restored panes can be stale — a file deleted, a session archived. Both are
already handled: `FilePaneAdapter` has `onVanished` and `ChatView` has
`onArchived`, and both resolve to closing that pane.

Knowledge's existing last-opened restore is the precedent for this pattern and
folds into it.

## Width behaviour

Everything open needs 236 + 300 + 380 + 300 + 300 = 1516px. Below that,
elements auto-hide **right to left** — pane 2, then pane 1, then the narrow
column — so things disappear from the outer edge inward and the primary view
is always last to give up space.

Auto-hidden elements keep their toggle state and reappear when the window
grows: the user never has to re-open something the window shrank away. The
`＋ Pane` control disables itself when the next pane would not fit, with the
reason on hover rather than a silent no-op.

`ChatView`'s `viewWidth >= 860` rail gate is the precedent for this rule but
is **not** replaced by it: the two operate at different levels. `pane-fit.ts`
decides which shell elements fit in the window; the rail gate decides what
fits inside whatever width `ChatView` ends up with. They compose without
knowing about each other, which is why opening a second pane makes the rail
retreat to its header pill with no coordination code.

## The bottom bar

A ~28px band across the content area only. Left: the narrow-column toggles for
this route. Right: `＋ Pane`, opening a short menu (Files… / Chat / Mail… /
A file…), with items already open shown as checked and inert.

Styling is deliberately furniture, not feature: `bg-paper-sidebar`,
`border-t border-paper-hairline`, inactive `text-ink-meta`, active
`text-ink-heading`. **No accent colour** — in this design system colour means
consequence (`PRODUCT.md` principle 1) and toggling a view has none.

Routes that are not pane hosts (Today, Tasks, Calendar, Audit, Sources) render
the bar with no toggles and no `＋`. It stays present as a stable piece of
furniture rather than appearing and disappearing as you navigate, and each
route populates it as it is converted.

### Why a bar at all

The feature only pays off if people find it, and the bar is the mechanism:
visible by presence, fixed in position, two controls. It also gives git sync
status and the workspace indicator an obvious future home, which today are
squeezed into the sidebar (`StatusPill`, `UpdateNotice`).

## Interaction details

**Chat opening a file.** Today `ChatView` auto-opens a file into the single
pane, guarded by `hasOpenPane()` so it never replaces what you are reading.
The generalised rule needs no provenance tracking: *replace an existing `file`
pane if there is one, otherwise fill a free slot, otherwise do nothing.* You
never accumulate file panes, and a chat or mail pane you opened yourself is
never taken.

**Duplicate suppression.** `panesEqual` already drops a pane that duplicates
the primary. It extends to deduplicating panes against each other, so opening
the same file twice is a no-op rather than two identical columns.

**Promote (⤢).** Unchanged. The pane's subject becomes the route you are on;
the remaining panes stay.

**Resizing.** `pane-split.ts` currently persists one percentage. It becomes a
layout array keyed by pane count (`valea.pane-split.<n>`), so going from two
columns to three and back does not lose either arrangement.

## Modules

Extended:

- `lib/panes/pane-route.ts` — `parsePanes(searchParams)`, `withPanes(url, list)`,
  cap enforcement, dedup, `?all=1` alias, `mail:` kind
- `lib/panes/pane-split.ts` — per-count layout arrays
- `lib/panes/registry.ts` — `mail` → `MailPaneAdapter`
- `lib/panes/context.ts` — `openPane(descriptor)` so a view can request a pane
- `lib/components/panes/PaneHost.svelte` — N panes; the unconditional-primary
  rule in its header comment is load-bearing and must survive (tearing the
  primary down on every pane change would drop the composer's draft and rejoin
  the session channel)
- `lib/components/shell/AppShell.svelte` — nav anchor, content column, bar.
  Its `rail` slot is dead code today — `AppFrame` forwards the prop and no
  route passes it — so removing it costs nothing.

New:

- `lib/panes/pane-memory.ts` — per-route persistence and the apply rule
- `lib/shell/content-bar.ts` — which toggles a route offers, and why `＋` is
  disabled
- `lib/shell/pane-fit.ts` — available width → how many panes and whether the
  column fits
- `lib/components/shell/ContentBar.svelte`
- `lib/components/panes/MailPaneAdapter.svelte`

Retired: `SessionHeader`'s popover file tree and `ChatView`'s
`treeRequestedFor` effect that loads its root; `AppShell`/`AppFrame`'s `rail`
snippet prop (unused); `AppFrame`'s `list` prop, replaced by the column
occupant. The file-activity rail and `filesPopover` stay as they are.

## Testing

The codebase convention is pure logic in `.ts` with a `.test.ts` sibling and
no component render harness (`pane-route.test.ts`, `pane-split.test.ts`,
`icm-route.test.ts`). Every decision above is placed to keep that possible:

- `pane-route.test.ts` — multi-pane parse/serialize round-trips; cap
  enforcement; dedup against primary and between panes; single-`?pane=`
  back-compat; `?all=1` → `?col=sessions`; invalid input fails closed
- `pane-memory.test.ts` — save/load; URL-wins-over-memory; storage failure
  degrades silently (the pattern `pane-split.ts` already uses)
- `content-bar.test.ts` — toggles offered per route; radio behaviour;
  disabled reasons
- `pane-fit.test.ts` — width thresholds; right-to-left hide order; toggle
  state survives an auto-hide

## Build order

One pass, but internally ordered so each step is separately reviewable:

1. `pane-route.ts` multi-pane codec + tests (no UI change; `?pane=` still
   single-valued in practice)
2. `PaneHost` renders N panes; `pane-split.ts` per-count layouts
3. `AppShell` restructure — nav anchor, content column, narrow column slot
4. `ContentBar` + `content-bar.ts` + `pane-fit.ts`
5. `pane-memory.ts` and the restore-on-entry rule
6. Route conversions: Chat (tree column replaces the popover), Knowledge, Mail
   (`PaneHost` + `MailPaneAdapter`)

## Open items for review

- **Nav collapse.** Agreed earlier in the discussion, then the nav was
  described as "the fixed anchor" — which governs its *position* (full height,
  the bar beside it rather than under it) and does not obviously settle
  whether it also hides. Proposal: keep the collapse, default on, toggled from
  the bar's far left; it is the first 236px worth reclaiming on a 13" screen.
  Confirm or cut.
- **`mail:<messageId>` durability.** Whether a mail pane in a remembered
  composition should survive a mailbox resync, or resolve to "message no
  longer available" and close like a vanished file.
