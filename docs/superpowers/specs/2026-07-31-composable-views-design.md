# Composable Views — Self-Contained Panes

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
system**. The shell learns exactly one new thing — that it holds a *row* of
panes rather than a primary plus one — and everything else is pushed inside
the panes, where it is private.

The explicit non-goal is a tiling window manager. Valea's user is a
non-technical solopreneur; the feature has to be legible on first sight and
impossible to get lost in.

## The organising principle

**Every pane is a navigator plus its content, and owns both.**

| Pane | Navigator | Content |
|---|---|---|
| Files | ICM tree | one or two file views |
| Mail | message list | the open message |
| Chat | sessions list | the transcript |

The navigator is optional in each and defaults per kind. This is what makes
the shell simple: it never learns that a tree relates to a file view, because
nothing outside the Files pane can observe that relationship.

## Decisions settled with Daniel (2026-07-31)

- **Build on the split pane, not on docks.** An earlier draft proposed
  Zed-style slots, a panel registry addressable per slot, per-center layout
  memory and a six-chip toggle bar. Rejected as *"almost too composable, which
  will confuse regular users"* — it invents a vocabulary the user must learn
  before it pays off.
- **Two panes beside the primary, hard cap.** The cap is what keeps this from
  becoming a tiling manager.
- **Panes are self-contained.** A middle draft gave the shell a narrow column
  whose occupant was chosen per route (tree / sessions / mail list), which
  meant the tree and the file panes had to be kept in sync *through the shell*
  — a shared `activePaths` prop, a shared reveal-path module, and a
  coordination rule for which pane a tree click targets. Replaced by putting
  the tree **inside** the Files pane: *"from the outside it is only one file
  pane, but the file pane itself is powerful. This way we don't need to sync
  separate panes with each other."* The sync problem is not solved, it stops
  existing.
- **The narrow column and `?col=` are therefore dropped entirely.** The shell
  knows nav plus a row of panes, nothing else. This reverses the earlier "the
  tree is a narrow column, not a pane" decision — the constraint behind it
  (the tree must never widen to pane proportions) now holds by construction,
  because the pane owns its own internal widths.
- **Mail follows the same principle**, so its list moves inside the Mail view
  and mail becomes usable as a pane — the "mail beside chat" case that made
  this app-level rather than a chat feature.
- **Only Files splits.** Comparing two files is a real need; comparing two
  transcripts or two mailboxes is not. Chat and Mail hold one subject each.
- **Controls go on a bottom bar inside the content container.** The left nav
  is a full-height fixed anchor; the bar sits *beside* it, not under it.
- **Panes are remembered per route.** A URL that names panes always wins.

## Layout

```
┌────────┬──────────────────────────────────────────────────┐
│        │ ┌──────────────┬─────────────────────────────┐   │
│        │ │  Chat        │ Files — life          ▣ ⤢ ✕ │   │
│  Nav   │ │  (primary)   ├──────┬──────────┬───────────┤   │
│  236   │ │              │ tree │ AGENTS.md│ CONTEXT.md│   │
│ (full  │ │              │ 240  │  split 1 │  split 2  │   │
│ height)│ └──────────────┴──────┴──────────┴───────────┘   │
│        │                                        ＋ Pane   │
└────────┴──────────────────────────────────────────────────┘
             └── shell sees 2 panes; 4 visible columns ──┘
```

`AppShell` becomes nav, a row of panes, and the bar:

```svelte
<div class="flex h-screen">
  <aside class="w-[236px] shrink-0 …">{@render nav()}</aside>
  <div class="flex min-w-0 flex-1 flex-col">
    <PaneRow panes={[primary, ...sidePanes]} />
    <ContentBar />
  </div>
</div>
```

Outer widths: nav 236 · panes flexible, minimum 380px for the primary and
300px for each side pane, divided by `PaneResizer` as today. `AppShell`'s
`list` and `rail` snippet props are removed — `rail` is already dead code
(`AppFrame` forwards it and no route passes it) and `list` is replaced by each
pane's own navigator.

## Pane kinds

| Kind | Wire form | Navigator | Status |
|---|---|---|---|
| files | `files:<mount>[/<path>[\|<path2>]]` | ICM tree | **new** |
| chat | `chat:<sessionId>` | sessions list | exists |
| chat-new | `chat:new:<mountKey>` | — | exists |
| mail | `mail[:<messageId>]` | message list | **new** |

The standalone `file:` kind from the side-panes spec is absorbed by `files:`.
A Files pane with its tree hidden *is* a plain file view, which is what you
want when a mail message opens a file and you did not ask for a browser.

### The Files pane

Internals: an optional ICM tree at a fixed 240px, and one or two file views
sharing the remainder. Its header carries the pane chrome (title · promote ·
close) plus two controls of its own — a tree toggle and `＋ Split`. Pane-level
controls live in the pane header, never in a second bottom bar; the shell's
bar is the only bar.

Everything the middle draft needed shell-level machinery for is now local
state in this one component:

- The tree marks **every** open split, so with two files both rows highlight.
- Opening a file expands its ancestors via `treeOpenState.open()` — already
  idempotent, already built for this — and scrolls the newest one into view.
  Only the newest: scrolling for both would fight itself.
- A tree click opens into the **first** split; a hover affordance on the row
  opens it as a second split instead. Deterministic, no focus concept — and
  because it is now private to one component, changing the rule later costs
  nothing outside it.
- `onBeforeMutate` (flush a pending edit before rename or delete) keys per
  href rather than off a single active path, so renaming either open file
  flushes the right split.

### The Mail pane

Message list plus reader, lifted out of `/mail`'s current `AppFrame` + `list`
snippet composition into one component. `mail` with no id is the list with
nothing selected.

### The Chat pane

Unchanged apart from its navigator: chat's existing `?all=1` all-sessions
column becomes the Chat pane's own optional sessions list, toggled from the
pane header like the Files tree. `?all=1` is kept as a parse-time alias.

## URL scheme

**Panes repeat the existing `pane` param** rather than introducing a delimited
one:

```
/chat?session=a91f&pane=files:life/AGENTS.md|CONTEXT.md
```

This buys back-compatibility for free: a single `?pane=` — every link and
bookmark in the wild today — parses as a one-element list with no special
case. Document order is left-to-right pane order, and a third `pane` param is
dropped on parse so a hand-written URL cannot exceed the cap.

The **primary** pane is addressed by the route as it is today
(`/chat?session=`, `/knowledge/<mount>/<path>`, `/mail?id=`); only a second
Files split needs a new param there (`?split=<path>`).

**Content is in the URL; chrome is a preference.** Which files a Files pane
has open is content and travels in the descriptor. Whether its tree is showing
is a per-kind preference in `localStorage`, shared by every Files pane. This
keeps the codec small and means a shared link reproduces what the sender was
looking at without also imposing their chrome habits.

## Memory

`localStorage`, one entry per route key:

```
valea.content.<routeKey> → string[]   // serialized side-pane descriptors
valea.pane-chrome        → { files: { tree: bool }, chat: { sessions: bool } }
```

Written on every change. Applied **only when the URL names no panes** —
entering `/chat` bare restores your last composition via
`goto(…, { replaceState: true })`, so the URL becomes explicit immediately and
the back button behaves. A URL carrying `pane` always wins, so a link shared
between two people is never rewritten by the recipient's habits.

Restored panes can be stale — a file deleted, a session archived, a message
gone after a resync. `FilePaneAdapter`'s `onVanished` and `ChatView`'s
`onArchived` already handle the first two by closing; mail follows whichever
of the two options in *Open items* is chosen.

## Width behaviour

Chat plus a Files pane with a tree and two splits needs
236 + 380 + 240 + 300 + 300 = 1456px. Pressure is relieved from the outside
in, at two levels:

1. **Shell.** Side panes auto-hide right to left, so content disappears from
   the outer edge and the primary is last to give up space.
2. **Inside a pane.** The Files pane drops its second split, then its tree.

Auto-hidden things keep their toggle state and return when the window grows —
the user never re-opens something the window took away. `＋ Pane` and
`＋ Split` disable themselves when the next one would not fit, with the reason
on hover rather than a silent no-op.

`ChatView`'s existing `viewWidth >= 860` rail gate is untouched and needs no
coordination: it measures `ChatView`'s own container, so opening a pane
shrinks the chat and the file-activity rail retreats to its header pill on its
own. `filesPopover` is that rail's fallback, not a file browser, and stays.

## The bottom bar

A ~28px band across the content area only. `＋ Pane` on the right, opening a
short menu (Files / Chat / Mail), with kinds already open shown as checked and
inert. Nav collapse sits at the far left if that open item is confirmed.

Styling is deliberately furniture, not feature: `bg-paper-sidebar`,
`border-t border-paper-hairline`, inactive `text-ink-meta`, active
`text-ink-heading`. **No accent colour** — in this design system colour means
consequence (`PRODUCT.md` principle 1) and opening a view has none.

Routes that are not pane hosts (Today, Tasks, Calendar, Audit, Sources) render
the bar without `＋`. It stays present as stable furniture rather than
appearing and disappearing as you navigate, and each route populates it as it
is converted.

The bar carries fewer controls than it did in the middle draft, because the
per-pane toggles moved into pane headers where they belong. It is still worth
having: the feature only pays off if people find it, and a control nobody
finds converts nobody. It also gives git sync status and the workspace
indicator an obvious future home, which today are squeezed into the sidebar
(`StatusPill`, `UpdateNotice`).

## Interaction details

**Chat opening a file.** Targets a Files pane: if one is open, the file lands
there; if not, one opens. Within the Files pane the rule tracks the split it
created (`autoSplit`, reset when the session changes):

1. if `autoSplit` still exists → replace **that** split
2. else if a split slot is free → open there
3. else → do nothing

So the assistant recycles its own split while a file you opened stays put —
you can pin your file on the right and let chat cycle references on the left.
Any user-initiated open into a split clears `autoSplit` for it. Rule 3 is the
conservative floor `hasOpenPane()` provides today: auto-open never evicts a
file the user placed.

**Duplicate suppression.** `panesEqual` already drops a pane duplicating the
primary. Two Files panes are likewise collapsed to one — opening a file when a
Files pane exists always routes into it rather than making a second browser.

**Promote (⤢).** The pane's subject becomes the route you are on; remaining
panes stay. For a Files pane with two splits, promoting carries both (the
route's `?split=` param).

**Resizing.** `pane-split.ts` currently persists one percentage. It becomes a
layout array keyed by pane count (`valea.pane-split.<n>`), with the Files
pane's internal split ratio persisted separately under its own key.

## Modules

Extended:

- `lib/panes/pane-route.ts` — repeated `pane` params; `files:` and `mail:`
  descriptors including the `|` split form; cap enforcement; dedup; `?all=1`
  alias
- `lib/panes/pane-split.ts` — per-count outer layouts
- `lib/panes/registry.ts` — `files` → `FilesPane`, `mail` → `MailPane`
- `lib/panes/context.ts` — `openFile` routes to a Files pane
- `lib/components/panes/PaneHost.svelte` — N panes. Its unconditional-primary
  rule is load-bearing and must survive: tearing the primary down on a pane
  change would drop the composer's draft and rejoin the session channel.
- `lib/components/shell/AppShell.svelte` — nav anchor, pane row, bar
- `lib/components/shell/IcmTree.svelte` — multiple marked rows, per-href
  `onBeforeMutate`

New:

- `lib/components/panes/FilesPane.svelte` — tree + splits; owns the sync
- `lib/components/panes/MailPane.svelte` — list + reader
- `lib/panes/files-pane-state.ts` — pure: open splits, cap, tree visibility,
  the tree-click target rule
- `lib/panes/auto-open.ts` — the three-step rule over splits and `autoSplit`
- `lib/panes/pane-memory.ts` — per-route persistence and the apply rule
- `lib/shell/reveal-path.ts` — ancestor hrefs for `treeOpenState`, lifted out
  of `routes/knowledge/[...path]/+page.svelte`
- `lib/shell/pane-fit.ts` — width → how many panes and splits fit
- `lib/components/shell/ContentBar.svelte`

Retired: `SessionHeader`'s popover file tree and `ChatView`'s
`treeRequestedFor` root-load effect; `AppShell`/`AppFrame`'s `list` and `rail`
props; `/mail`'s `AppFrame` + `ListPane` composition; the standalone `file:`
pane kind.

## Testing

The codebase convention is pure logic in `.ts` with a `.test.ts` sibling and
no component render harness (`pane-route.test.ts`, `pane-split.test.ts`,
`icm-route.test.ts`). Every decision above is placed to keep that possible:

- `pane-route.test.ts` — multi-pane parse/serialize round-trips; the `|` split
  form; cap enforcement; dedup against primary and between panes;
  single-`?pane=` back-compat; `?all=1` alias; invalid input fails closed
- `files-pane-state.test.ts` — split cap; tree-click targets the first split;
  hover-open adds a second; closing the last split leaves a tree-only pane
- `auto-open.test.ts` — recycles its own split; never evicts a user's; falls
  back to a free slot; no-ops when full; a user open clears the mark
- `pane-memory.test.ts` — save/load; URL wins over memory; storage failure
  degrades silently (the pattern `pane-split.ts` already uses)
- `reveal-path.test.ts` — ancestor href derivation, mount roots, encoded
  segments
- `pane-fit.test.ts` — thresholds at both levels; outside-in hide order;
  toggle state survives an auto-hide

## Build order

One pass, internally ordered so each step is separately reviewable:

1. `pane-route.ts` — repeated params, `files:`/`mail:` descriptors + tests
   (no UI change)
2. `PaneHost` renders N panes; `pane-split.ts` per-count layouts
3. `FilesPane` — tree + splits + `files-pane-state.ts` + `reveal-path.ts`;
   `IcmTree` multi-mark and per-href `onBeforeMutate`
4. `AppShell` restructure — nav anchor, pane row; `list`/`rail` removed
5. `ContentBar` + `pane-fit.ts`
6. `pane-memory.ts` and restore-on-entry
7. `auto-open.ts` and the chat tool-chip path
8. Route conversions: Knowledge → `FilesPane`, Chat → sessions navigator,
   Mail → `MailPane`

## Open items for review

- **Nav collapse.** Agreed early, then the nav was described as "the fixed
  anchor" — which governs its *position* (full height, bar beside it) and does
  not obviously settle whether it also hides. Proposal: keep it, default on,
  toggled from the bar's far left. Confirm or cut.
- **Stale mail panes.** Whether a remembered `mail:<id>` whose message is gone
  after a resync closes quietly like a vanished file, or holds a "no longer
  available" state until dismissed.
