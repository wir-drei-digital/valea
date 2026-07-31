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
    <PaneHost {primary} panes={sidePanes} … />
    <ContentBar />
  </div>
</div>
```

`PaneHost` keeps its name and owns the whole row — there is no separate
`PaneRow`. It already wraps `paneforge`'s `PaneGroup`/`Pane`/`PaneResizer` and
already holds the "primary is mounted unconditionally" rule that everything
here depends on; growing it from one side pane to two is the smaller change
and leaves one component owning the outer layout and resize API.

Outer widths: nav 236 · panes flexible, minimum 380px for the primary and
300px for each side pane, divided by `PaneResizer` as today.

`AppShell`'s `list` and `rail` snippet props are removed — `rail` is already
dead code (`AppFrame` forwards it and no route passes it) and `list` is
replaced by each pane's own navigator. **The `list` removal ships in the same
change as the route conversions that stop using it**, since Chat, Mail and
Knowledge all still compose through it until then; see *Build order*.

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

**At most one Files surface exists at a time**, counting the primary. On
`/knowledge` the primary *is* the Files surface, so a Files side pane there is
rejected by the same `panesEqual` guard that already rejects a pane
duplicating the primary. This is not merely tidiness: `treeOpenState` is a
persisted global singleton keyed by href
(`lib/stores/tree-state.svelte.ts`), so two Files surfaces would silently
share expansion state. One surface makes that sharing correct by
construction rather than accidental, and it is why tree visibility can be a
single global preference without ambiguity.

A `files:` path may be a **folder** as well as a file — `/knowledge`'s route
already renders folder listings — in which case the split shows the folder
view. `files:<mount>` with no path is the tree with an empty content area.

The Knowledge **index** (mount selection, degraded and deactivated mounts,
create, unmount, doctor actions) stays route-only. It is workspace
administration, not file browsing, and has no pane representation.

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
- `onBeforeMutate` (flush a pending edit before rename or delete) becomes
  `onBeforeMutate(href)`. Today `IcmTree` takes a single callback and forwards
  it only for the row matching `activePath`
  (`lib/components/shell/IcmTree.svelte:31,168`), and the Knowledge route
  binds exactly one `FileView` ref. `FilesPane` holds a **split → `FileView`
  ref map** and dispatches by href, so renaming either open file flushes that
  split and not the other. Without this, a rename can flush the wrong editor
  or skip an unsaved edit.

### The Mail pane

**Scope boundary.** `/mail` is much more than a list and a reader: it owns
account-qualified selection with race suppression, search with debounce, the
drafts panel (`?drafts=1`), compose (`?compose=`), and the setup modal
(`?setup=1`). Extracting all of that into a pane would either duplicate state
or break compose and account switching.

So a **Mail pane is the read surface only** — account-scoped message list plus
the open message. Compose, drafts and setup are full-screen tasks rather than
things you glance at beside a transcript, and they stay route-only. The route
composes the same `MailPane` component plus its own modes, so list-and-reader
has one implementation used by both. Promoting a Mail pane lands on `/mail`
with the full route and its modes available again.

### The Chat pane

Chat's navigator is its all-sessions list, today the route's `?all=1` column.
Extracting it is **route work, not a `ChatView` toggle**: `showAllPane`, the
grouping, the archive-per-row path and the include-scheduled checkbox all live
in `routes/chat/+page.svelte:70-78,259-346`, and `ChatView` is documented as
never reading `page.url` itself (`ChatView.svelte:8`) precisely so it can be
mounted in a pane. The list moves into the Chat pane component alongside
`ChatView`; the pane's descriptor, not the URL, tells it whether the navigator
is showing. `?all=1` is kept as a parse-time alias onto that.

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

The **primary** pane is addressed by the route as it is today —
`/chat?session=`, `/knowledge/<mount>/<path>`, and `/mail?message=` qualified
by `?account=` (not `?id=`). Only a second Files split needs a new param
(`?split=<path>`).

**Promotion merge rules.** `promoteHref` today returns a bare route and drops
everything else (`lib/panes/pane-route.ts:132-142`). Promoting from a
composition must instead: build the target route href with that kind's own
params (`session`; `message` + `account`; mount path + `split`), re-attach the
**remaining** panes with `withPanes`, drop the promoted pane from that list,
and then run the same duplicate suppression — so promoting a Files pane on a
route whose primary becomes Files does not leave a redundant copy beside it.
Route params belonging to the *old* primary (`all`, `icm`, `drafts`,
`compose`, `setup`) are not carried across a kind change.

**Content is in the URL; chrome is a preference.** Which files a Files pane
has open is content and travels in the descriptor. Whether its tree is showing
is a per-kind preference in `localStorage`, shared by every Files pane. This
keeps the codec small and means a shared link reproduces what the sender was
looking at without also imposing their chrome habits.

## Memory

`localStorage`, one entry per route key:

```
valea.content.<routeKey> → { v: 1, panes: string[] }
valea.pane-chrome        → { files: { tree: bool }, chat: { sessions: bool } }
```

`routeKey` is the **route id alone** — `chat`, `mail`, `knowledge` — never
qualified by params. Which session, account, folder or mount you had open is
the primary's business and already lives in the route; qualifying the key
would fragment memory into hundreds of entries that each restore once. The
`v` field allows a format change to be discarded rather than mis-parsed.

Stored descriptors are re-parsed on restore and **invalid ones are dropped and
rewritten**, so a descriptor left over from an older codec cannot wedge a
route. A pane that parses but whose subject has since vanished is handled at
mount time by the rules below, not at restore time — the storage layer does no
existence checking.

Written on every change. Applied **only when the URL names no panes** —
entering `/chat` bare restores your last composition via
`goto(…, { replaceState: true })`, so the URL becomes explicit immediately and
the back button behaves. A URL carrying `pane` always wins, so a link shared
between two people is never rewritten by the recipient's habits.

Restored panes can be stale — a file deleted, a session archived, a message
gone after a resync. **The host, not the view, decides what that means.**
`FileView` raises `onVanished` and `FilePaneAdapter` merely forwards it to
`context.onArchived` (`FilePaneAdapter.svelte:16`); nothing in the adapter
closes anything. So `PaneHost` must supply a concrete handler to every mounted
pane, and the rule is uniform: **a pane whose subject no longer exists closes
itself and is removed from memory.** Mail follows the same rule rather than
holding an error state — a layout that quietly shrinks is less alarming than
one carrying a tombstone, and the message list beside it already explains
where things went.

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

**Auto-hide means hidden, never unmounted.** This is load-bearing and easy to
get wrong. A `ChatView` owns an `AgentSessionStore` that it disposes on
teardown, so unmounting a hidden chat pane would leave the session channel,
discard the composer's unsent draft, and replay the transcript on return —
the exact failure `PaneHost`'s existing header comment forbids for the
primary. Hidden panes therefore stay mounted with their subtree display-hidden
and are excluded from the resize group's layout.

Two consequences to honour: a hidden pane's `clientWidth` binding reads 0, so
views that gate on their own width must fail closed rather than throw
(`ChatView`'s `viewWidth >= 860` already does — at 0 the rail simply hides);
and hidden panes must not be rendered by the resizer as zero-width panes,
which would let a drag resurrect them at an unusable size.

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

**Chat opening a file.** Every mounted Chat surface needs pane-aware
callbacks, not just the primary: today the route passes `openFile` to the
primary `ChatView` but mounts a side-pane one without it
(`routes/chat/+page.svelte:360-367,395-402`), so a chat in a pane cannot open
files at all. `PaneHost` supplies the callbacks to every chat it mounts, and
they resolve against the whole pane list so the URL is rewritten atomically
rather than per-pane.

The file targets the single Files surface: if one is open (primary or pane)
the file lands there; if not, a Files pane opens. Within it the rule tracks
the split it created (`autoSplit`, reset when the session changes):

1. if `autoSplit` still exists → replace **that** split
2. else if a split slot is free → open there
3. else → do nothing

So the assistant recycles its own split while a file you opened stays put —
you can pin your file on the right and let chat cycle references on the left.
Any user-initiated open into a split clears `autoSplit` for it. Rule 3 is the
conservative floor `hasOpenPane()` provides today: auto-open never evicts a
file the user placed.

**Duplicate suppression.** `panesEqual` already drops a pane duplicating the
primary. It extends to **one surface per kind** across the primary and both
panes: a second Files or Mail or Chat surface is collapsed into the existing
one, so opening a file always routes into the Files surface that exists rather
than making a second browser. The one exception is `chat-new` beside a
`chat`, which is a distinct kind and is how you start a session while reading
an old one — a path Knowledge already offers.

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

- `lib/components/panes/FilesPane.svelte` — tree + splits; owns the sync and
  the split→`FileView` ref map that `onBeforeMutate(href)` dispatches over
- `lib/components/panes/MailPane.svelte` — the read surface (list + reader),
  consumed by both the pane registry and `/mail` itself
- `lib/components/panes/ChatPane.svelte` — sessions navigator + `ChatView`,
  holding the route logic lifted out of `routes/chat/+page.svelte`
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
- `pane-memory.test.ts` — save/load; URL wins over memory; route keys are
  param-free; a `v` mismatch or unparseable descriptor is dropped and
  rewritten; storage failure degrades silently (the pattern `pane-split.ts`
  already uses)
- `pane-route.test.ts` also covers promotion: remaining panes survive, the
  promoted one is dropped, kind-specific params (`session`, `message` +
  `account`, `split`) are carried and the old primary's are not
- `reveal-path.test.ts` — ancestor href derivation, mount roots, encoded
  segments
- `pane-fit.test.ts` — thresholds at both levels; outside-in hide order;
  toggle state survives an auto-hide

## Build order

One pass, internally ordered so each step is separately reviewable:

1. `pane-route.ts` — repeated params, `files:`/`mail:` descriptors, promotion
   merge rules + tests (no UI change)
2. `PaneHost` renders N panes, hidden-not-unmounted; `pane-split.ts`
   per-count layouts
3. `FilesPane` — tree + splits + `files-pane-state.ts` + `reveal-path.ts`;
   `IcmTree` multi-mark and `onBeforeMutate(href)` over a split→ref map
4. `MailPane` — the read surface extracted from `/mail`, still consumed by
   the route
5. **`AppShell` restructure and route conversions together** — nav anchor,
   pane row, `list`/`rail` removed, and Knowledge/Chat/Mail moved onto
   `PaneHost` in the same change. These cannot be separated: the routes
   depend on `list` until they are converted, so removing it first would
   leave the tree broken between steps.
6. `ContentBar` + `pane-fit.ts`
7. `pane-memory.ts` and restore-on-entry
8. `auto-open.ts` and the chat tool-chip path

## Open items for review

- **Nav collapse.** Agreed early, then the nav was described as "the fixed
  anchor" — which governs its *position* (full height, bar beside it) and does
  not obviously settle whether it also hides. Proposal: keep it, default on,
  toggled from the bar's far left. Confirm or cut.
*(Stale mail panes were an open item and are now settled under Memory: any
pane whose subject vanishes closes and is dropped from storage, mail
included.)*
