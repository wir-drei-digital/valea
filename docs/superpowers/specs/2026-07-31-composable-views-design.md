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
| Files | ICM tree | a strip of tabs, one file showing |
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
- **Only Files shows two subjects at once.** Comparing two files is a real
  need; comparing two transcripts or two mailboxes is not. Chat and Mail hold
  one subject each. (Since the 2026-08-01 tabs amendment, Files holds six tabs
  and shows one — two only through the explicit Compare control.)
- **Controls go on a bottom bar inside the content container.** The left nav
  is a full-height fixed anchor; the bar sits *beside* it, not under it.
- **Panes are remembered per route.** A URL that names panes always wins.

## Layout

```
┌────────┬──────────────────────────────────────────────────┐
│        │ ┌──────────────┬─────────────────────────────┐   │
│        │ │  Chat        │ Files — AGENTS.md   ▣ ⧉ ⤢ ✕ │   │
│  Nav   │ │  (primary)   ├──────────────────────┬──────┤   │
│  236   │ │              │ [AGENTS] [CONTEXT ✕] │      │   │
│ (full  │ │              ├──────────────────────┤ tree │   │
│ height)│ │              │ the active tab's file│ 240  │   │
│        │ └──────────────┴──────────────────────┴──────┘   │
│        │                                        ＋ Pane   │
└────────┴──────────────────────────────────────────────────┘
             └── shell sees 2 panes; 3 visible columns ──┘
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
| files | `files:<mount>[/<p1>[\|<p2>…][@<i>[+<j>]]]` | ICM tree | **new** |
| chat | `chat:<sessionId>` | sessions list | exists |
| chat-new | `chat:new:<mountKey>` | — | exists |
| mail | `mail:<account>[/<messageId>]` | message list | **new** |

The mail descriptor carries the **account**, not a bare message id. A message
id is only unique within an account — `/mail` selects on `?message=` qualified
by `?account=`, and `MessageList` puts the account in every row href
(`lib/components/mail/MessageList.svelte:69`) for exactly this reason. A
`mail:<messageId>` form would silently resolve to the wrong message when two
accounts are configured.

The standalone `file:` kind from the side-panes spec is absorbed by `files:`.
A Files pane with its tree hidden *is* a plain file view, which is what you
want when a mail message opens a file and you did not ask for a browser.

### The Files pane

**AMENDMENT (2026-08-01, Daniel): the Files pane is TABS, and the tree is on
the RIGHT.** Splits were the original design and they lost the width argument
on every laptop: two files needed a 1439px window, `SPLIT_MIN` had to come down
from 300 to 240 to reach one at all, and a pane a tool chip created could still
starve a file to twenty pixels. A tab costs no width. **This landed** — the
paragraphs below describe it; the split-era text that survives is marked where
it is still true.

Internals, left to right: a **tab strip** across the top of the content area,
the active tab's file below it, and an optional ICM tree at a fixed 240px down
the **right** edge. `treeFits` is unchanged and simply measures the other side
now.

**Tabs.**

- Cap **6**. Opening a seventh replaces the **oldest inactive** tab (lowest
  index, which is open order), never the active one, and replaces it **in
  place** so no surviving index is renumbered. No scrolling strip, no overflow
  chrome.
- Exactly one tab is active. A tab shows its basename and carries the full path
  as its `title`. Each has a ✕; closing the active tab activates its left
  neighbour, or its right if it was first.
- **`+` opens a pending empty tab** — active, showing "Pick a file to read it."
  It is local state, not URL state: it holds nothing, so a reload legitimately
  loses it. At most one exists; `+` while one is pending is a no-op. While it
  is showing, NO tab and no tree row reads as current, because nothing is.

**Tree → tab.**

- A tree row's plain click **replaces the active tab's file** — the tree drives
  the open tab, which is what makes browsing cost no tabs at all. With a
  pending tab active it materialises into that tab; with no tabs at all it
  opens the first.
- The row's hover affordance is **"Open in a new tab"**, same position and same
  `aria-disabled`-with-reason pattern as the "Open beside" it replaces. The
  only reason it can be disabled is the 6-tab cap, never width. It refuses at
  the cap rather than evicting: it is a secondary affordance on a row whose
  plain click already does something, and silently destroying a tab from one
  would be the cost the ＋ Split control was deleted for. The eviction rule
  above is for `+`-then-pick, which is an unambiguous request for a new tab.
- Every open tab is marked in the tree; the **active** one more strongly (the
  tree's active background versus ink weight alone — no accent colour, since
  being open is not a consequence). Ancestor reveal and scroll-into-view follow
  the active tab only.

**The compare escape.** True side-by-side survives as one explicit control in
the pane header (`Columns2`, `aria-pressed`), and it is the last thing in this
feature that consults a width.

- Enabled when `splitsThatFit(paneWidth, treeShown) >= 2` **and** at least two
  tabs exist; otherwise `aria-disabled` with the reason, never a silent no-op.
- On: the active tab and the **previously active** tab side by side, active on
  the left, sharing the content area through the existing
  `PaneGroup`/`PaneResizer` and the `loadFilesSplit`/`saveFilesSplit` ratio.
  "Previously active" is tracked as a PATH, not an index, because the list
  renumbers; with no history it falls back to the neighbour rather than
  refusing a control the user can see is available.
- Below the width threshold it falls back to the active tab alone **without
  rewriting the descriptor**, so widening the window brings the comparison
  back. The header reads what is RENDERED, so its pressed state can never
  announce a column that is not there. Turning it off closes neither tab.

**Wire form.** `@` is a safe cursor separator for the same reason `|` is a safe
tab separator: `encodeURIComponent` escapes both, so neither can appear inside
an encoded path segment.

```
files:<mount>                          tree only, no tabs
files:<mount>/<p1>                     one tab, active
files:<mount>/<p1>|<p2>|<p3>@1         three tabs, the second active
files:<mount>/<p1>|<p2>@0+1            compare on, tabs 0 and 1 side by side
```

`@<n>` absent means active 0. An out-of-range index clamps to 0 and an
unhonourable compare is dropped, rather than failing the whole descriptor — the
tabs are still valid content. A list longer than 6 truncates to the first 6
distinct paths. Malformed cursor SYNTAX (`@x`, `@1+`, `@1@2`) still fails
closed, and so does every pre-existing invalid case.

**The primary Files surface** (`/knowledge/<mount>/<path...>`) is the same
component, so it needs the same six tabs addressable. It is a route, so the
file being read stays in the pathname and the strip travels beside it:
`?tabs=<p1>|<p2>|…` carries the whole strip in order and `?compare=<n>` the
comparison. This replaces `?split=<path>`, which could only ever address the
second of two splits. `files-url.ts` owns both directions, and the pathname
wins if a hand-written URL disagrees with its own strip.

`SPLIT_MIN` and `splitsThatFit` are NOT deleted — compare needs both. What
`SPLIT_MIN` no longer does is gate opening a file.

**The `FILES` overline is gone** from both file views. It named the section of
the app you were in, above a path that already named the file; with a tab strip
overhead it was the outer of two labels for one fact. The Friendly/Raw toggle,
the save state, the token estimate and the path all stay.

*(Historical, for the reasoning that produced the split design and the
constraints that still hold: an optional ICM tree at a fixed 240px, and one or
two file views sharing the remainder.)*

**Pane chrome stays owned by `PaneHost`.** It already renders title, promote
and close around every side view (`PaneHost.svelte:96-120`), and duplicating
that inside `FilesPane` would give the Files pane two headers or divergent
behaviour from Chat and Mail.

Per-kind controls therefore cannot be a snippet handed *upward* from the pane
component: `PaneHost` renders the header before mounting the view, and the
registry is a flat kind → component map taking only `{descriptor, context}`
(`lib/panes/registry.ts:13-24`). A child cannot pass stateful chrome back to a
parent that has already rendered.

Instead the **host owns the state and renders both sides of it.** A registry
entry grows from a bare component to:

```ts
type PaneEntry = {
  view: Component<{ descriptor; context; state? }>;
  controls?: Component<{ state }>;   // rendered inside PaneHost's header
  createState?: (descriptor) => PaneState;
};
```

`PaneHost` calls `createState(descriptor)` once per pane, passes the result to
the header's `controls` component and to the body's `view` component, and
disposes it with the pane. So `FilesPaneState` (tree visibility, open splits,
whether another split fits) is written by the header's toggle and read by the
body, with neither component parenting the other. Kinds needing no extras —
`file`, `chat-new` — simply omit `controls` and `createState`, and the entry
degrades to today's shape.

**At most one Files surface exists at a time**, counting the primary. This
needs a **new rule**, not the existing guard: `panesEqual`
(`lib/panes/pane-route.ts:70-80`) compares descriptor *identity* — same kind
and same path — and `/knowledge`'s index deliberately has
`primaryDescriptor = null` (`routes/knowledge/+page.svelte:79-85`), so a Files
pane there is not caught by it. `dedupeSurfaces` is a separate pass over
`[primary, ...panes]` that collapses same-kind surfaces regardless of subject.

The single-surface rule is not tidiness. `treeOpenState` is a persisted global
singleton keyed by href (`lib/stores/tree-state.svelte.ts:45-64`), so two
Files surfaces would silently share expansion state. One surface makes that
sharing correct by construction, and is why tree visibility can be one global
preference without ambiguity.

**Folders expand, they do not open.** Only files are valid split subjects.
Clicking a folder in the tree expands it exactly as it does today; it never
takes a split. This is a deliberate simplification over the route's current
behaviour, which renders a folder path as a bare "Pick a page from the list"
header with no listing (`routes/knowledge/[...path]/+page.svelte:305-308`) —
there is no folder-content component to reuse, and inventing one would mean
designing selection, create, rename and delete inside a split. `files:<mount>`
with no path is the tree with an empty content area, which is what a folder
navigation now produces.

The Knowledge **index** (mount selection, degraded and deactivated mounts,
create, unmount, doctor actions) stays route-only. It is workspace
administration, not file browsing, and has no pane representation.

Everything the middle draft needed shell-level machinery for is now local
state in this one component:

- The tree marks **every** open tab, and the active one more strongly.
- Opening a file expands its ancestors via `treeOpenState.open()` — already
  idempotent, already built for this — and scrolls the ACTIVE tab into view.
  Only that one: revealing for every open tab would fight itself.
- A tree click replaces the **active tab**; the row's hover affordance opens a
  new one instead. Deterministic, no focus concept — and because it is private
  to one component, changing the rule later costs nothing outside it. (Written
  as "first split" / "second split" before the 2026-08-01 tabs amendment; the
  shape of the rule is the same, what an index counts is not.)
- `onBeforeMutate` (flush a pending edit before rename or delete) becomes
  `onBeforeMutate(href)`. Today `IcmTree` takes a single callback and forwards
  it only for the row matching `activePath`
  (`lib/components/shell/IcmTree.svelte:31,168`), and the Knowledge route
  binds exactly one `FileView` ref. `FilesPane` holds an **open file →
  `FileView` ref map** and dispatches by href, so renaming a compared file
  flushes that column and not its sibling. Only RENDERED files are in the map:
  a tab that is not showing has no editor mounted to flush. Without this, a rename can flush the wrong editor
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

**AMENDMENT (2026-08-01, Daniel).** The "one implementation used by both"
claim above proved false and is retired. `/mail`'s list carries an account
switcher, debounced search, a folder picker, a read filter, pagination and a
sync footer — none of which belong in a pane, and swapping `MailPane` into the
route would have deleted all of them. What is genuinely shared is
`MessageList` + `MessageView`; `MailPane` is a third composition of them. The
real cost was the ~40-line race-suppressed selection effect, once duplicated
near-verbatim in `MailPane` and the route — and its own comments record that
the race was caught live once already. **This landed:** it lives in one
`mail-selection` helper that both hosts call, with no private copy left in
either. Settled, not an outstanding obligation.

**Reuse needs a navigation adapter, not just extraction.** `MessageList`
renders each row as an anchor to `messageHref(account, msgId)`
(`lib/components/mail/MessageList.svelte:69`), which a pane must not follow —
clicking a row inside a pane has to rewrite that pane's descriptor, not
navigate the whole app to `/mail`. `MailPane` therefore takes selection as
callbacks rather than hardcoding hrefs:

- `onSelect(account, msgId)` — the route passes a `goto`; the pane passes a
  descriptor rewrite
- `onAccountChange(account)` — same split
- selection state, loading and the route's existing race suppression
  (`routes/mail/+page.svelte:118-163`) stay with whoever owns the URL

Without this the "one implementation" forks on first contact. It is the same
shape `PaneContext.openFile` already uses to let one view behave differently
per host.

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
by `?account=` (not `?id=`). The Files primary's other TABS need params of
their own — `?tabs=<p1>|<p2>|…` and `?compare=<n>`, with the active tab in the
pathname (see the Files pane's 2026-08-01 amendment). This replaced the
`?split=<path>` this paragraph originally specified.

**Promotion merge rules.** `promoteHref` today returns a bare route and drops
everything else (`lib/panes/pane-route.ts:132-142`). Promoting from a
composition must instead: build the target route href with that kind's own
params (`session`; `message` + `account`; mount path + `tabs`/`compare`), re-attach the
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
`context.onArchived` (`FilePaneAdapter.svelte:15`); nothing in the adapter
closes anything. So `PaneHost` must supply a concrete handler to every mounted
pane.

The rule is **per subject, not per pane**: a vanished subject is removed, and
the pane closes only when it has nothing left. This matters because a Files
descriptor can name two files — closing the whole pane because one of them was
deleted would discard the others and any pending edit in them (six, since the
tabs amendment). So a deleted tab is dropped — through `closeTab`, so the
cursor renumbers with the list — and its siblings stay; a Files pane with no
files left
survives as tree-only; a Chat or Mail pane, having one subject, closes
outright. Mail closes rather than holding a tombstone — a layout that quietly
shrinks is less alarming than one carrying a dead panel, and the message list
beside it already explains where things went.

Self-closing uses `replaceState`, so Back never steps through a pane that
immediately removes itself. Chat's existing `replacePaneWithSession` sets the
same precedent (`routes/chat/+page.svelte:241-247`).

## Width behaviour

**AMENDMENT (2026-08-01, Daniel): tabs took most of this section's pressure
away.** A Files pane now shows ONE file, so the arrangement it has to afford is
`nav + primary + tree + one file`, not `+ two files`. What survives unchanged:
`treeFits`, which drops the navigator rather than starving the file, and the
constants — `SPLIT_MIN` and `splitsThatFit` are still live, because the Compare
control is a genuine two-column arrangement and is gated on exactly the figure
below. Verified live: chat beside a Files pane with its tree AND a readable
file needs a ~1512px window; the same pane keeps a full-width file with the
tree dropped at every width below that, where the old design gave it a 60px
column.

Chat plus a Files pane with a tree and two splits needs
236 + 380 + 240 + 240 + 240 = 1336px of MINIMA. That is a floor, not a
reachable width: the row shares `window - 239` at 60/40, so what a side pane
actually gets is `0.4 * (window - 239)` and the window figures below are all
that inverse (`pane-fit.ts`'s header carries the derivation).

**AMENDMENT (2026-08-01, Daniel): `SPLIT_MIN` is 240, not 300.** At 300 the
arithmetic put two files side by side out of reach on every laptop — a side
Files pane cleared it only at 2339px with the tree shown, or 1739px hidden,
and with the `＋ Split` control deleted there was no other route to a second
split. (At 240 those become 2039px and 1439px, and a PRIMARY-width Files pane
clears the tree-shown case at 1439px, which is the arrangement the originating
ask actually describes.) That contradicted one of this feature's originating asks. 240px is
narrow but genuinely readable against the 596px prose cap: it degrades rather
than blocking. When less is available, what gets
dropped is decided from the outside in — side panes right to left, so the
primary is last to give up space, and within a Files pane the second compared
file before the tree.

**But that decision is made when a pane opens or is restored — never on
resize.**

An earlier draft had panes auto-hide as the window narrowed and return when it
grew. That is not implementable without a parking or portal strategy, and the
reason is instructive: a mounted side view lives directly inside a registered
`paneforge` `Pane` (`PaneHost.svelte:71-122`). Removing it destroys its
subtree, and a `ChatView` disposes its `AgentSessionStore` on teardown — so
a narrowing window would leave the session channel, discard the composer's
unsent draft and replay the transcript, which is the exact failure `PaneHost`'s
header comment forbids for the primary. Keeping it registered but
display-hidden leaves a zero-width pane a drag can resurrect.

Rather than build machinery to make continuous auto-hide safe, the rule
narrows: **`pane-fit.ts` is consulted only at the moments a pane would be
added** — `＋ Pane`, a tool chip opening a file, and restore from
memory. Panes that do not fit are not opened, and on restore the composition
is truncated from the right while memory keeps the full list, so the pane
returns on a wider window the next time you enter the route. Resizing the
window never mounts or unmounts anything.

The cost is honest and small: shrink the window with three columns already
open and they get cramped until you close one yourself. In exchange, panes
appear and disappear only in response to something the user did, component
identity is never in question, and "layout keyed by pane count" is
unambiguous because mounted, visible and requested counts are always equal.

`＋ Pane` disables itself when another pane would not fit, with the reason on
hover rather than a silent no-op.

**AMENDMENT (2026-08-01, Daniel): there is no `＋ Split` control.** *(Splits
themselves were replaced by tabs later the same day; the reasoning below is
what produced the tree row's per-file affordance, which survives as "Open in a
new tab".)* It was
specced, built, then removed. Any such button must *guess* which file to open —
the plan's "first file in the tree" finds nothing in a real ICM, since
top-level entries are folders — and a guess whose cost is opening the wrong
file, possibly replacing something you were reading, is worse than no control.
The tree's per-row "Open beside" affordance names the file you actually want
and is the only way to open a second split.

`ChatView`'s existing `viewWidth >= 860` rail gate is untouched and needs no
coordination: it measures `ChatView`'s own container, so opening a pane
shrinks the chat and the file-activity rail retreats to its header pill on its
own. `filesPopover` is that rail's fallback, not a file browser, and stays.

## The bottom bar

A ~28px band across the content area only. `＋ Pane` on the right, opening a
short menu (Files / Chat / Mail), with kinds already open shown as checked and
inert. Nav collapse sits at the far left — confirmed, shipped, and persisted
(every route mounts its own `AppShell`, so a collapse held in component state
would spring back open on the next navigation).

**Every menu item must name a concrete subject**, since no descriptor kind
accepts "empty":

| Item | Opens | When unavailable |
|---|---|---|
| Files | `files:<mount>` — tree, no file open | no enabled ICM |
| Chat | `chat:new:<mount>` — the new-session composer, which is what the existing `chat-new` kind is for; pick an existing session from the pane's own navigator | no enabled ICM |
| Mail | `mail:<account>` — list, nothing selected | no account configured *and* status is known |

`<mount>` is resolved by **`resolveIcmSelection(?icm, enabledMountKeys)`**, not
by `resolveActiveMountKey`. The latter bottoms out at `?icm=`
(`lib/shell/icm-route.ts:73`) and so returns `null` on Today or Tasks, which
would disable both items despite a perfectly good workspace.
`resolveIcmSelection` is the helper `/chat`'s own `primaryMountKey()` already
uses for exactly this "pick a sensible mount" job, falling back to the first
enabled, non-degraded mount in config order.

`<account>` is `mailStore.selectedAccount`, falling back to the first
configured account. **Unknown is not the same as absent:** `mailStore.accounts`
starts empty and only fills on `refreshStatus()`, which today only `/mail`
calls on mount (`lib/stores/mail.svelte.ts:448-449`,
`routes/mail/+page.svelte:54-56`). Opening the menu beside a chat would
otherwise report "No mail account yet" before anything had been fetched. So
`AppShell` kicks a one-time `refreshStatus()`, and until status is known the
item stays **enabled** — the Mail pane renders its own no-account empty state,
which is both truthful and recoverable. Availability is only ever asserted
from loaded data.

Genuinely unavailable items are shown disabled with the reason rather than
hidden — "No mail account yet" teaches something; a missing row does not.

Styling is deliberately furniture, not feature: `bg-paper-sidebar`,
`border-t border-paper-hairline`, inactive `text-ink-meta`, active
`text-ink-heading`. **No accent colour** — in this design system colour means
consequence (`PRODUCT.md` principle 1) and opening a view has none.

Routes that are not pane hosts (Today, Tasks, Calendar, Audit, Sources) render
the bar without `＋`. It stays present as stable furniture rather than
appearing and disappearing as you navigate, and each route populates it as it
is converted.

Structurally there is **one path, not two**: every route renders through
`PaneHost` with a primary, and a non-pane-host route simply never has side
panes. `PaneHost` already handles this — a lone pane lays out at `[100]`,
which its own header comment calls out — so those routes keep passing a plain
`main` snippet and gain the bar without any per-route work. No route bypasses
the shell to render content directly.

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
the TAB it created (`autoIndex`/`autoPath`, reset when the session changes;
`autoSplit` in this paragraph's original wording):

1. if the claimed tab still exists → replace **that** tab
2. else if the strip is below the cap → open a new one
3. else → do nothing

So the assistant recycles its own tab while a file you opened stays put — you
can keep your file in one tab and let chat cycle references through another.
Any user-initiated open into a tab clears the claim on it, and the file the
assistant opens becomes the SHOWING tab, because a citation that arrives behind
the tab you are reading is one you never see. Rule 3 is why auto-open does not
use the cap eviction the ＋ button does: a ＋ press is a person asking for a
tab; an assistant read is not. Rule 3 is the
conservative floor `hasOpenPane()` provides today: auto-open never evicts a
file the user placed.

**Duplicate suppression** happens at two levels. `panesEqual` keeps its job —
identity, dropping a pane whose subject matches the primary's. A new
`dedupeSurfaces` pass adds the coarser rule: **one surface per descriptor
kind** across the primary and both panes, regardless of subject, so opening a
file routes into the Files surface that already exists rather than making a
second browser. `chat-new` is a distinct kind from `chat` and so may sit
beside one — that is how you start a session while reading an old one, a path
Knowledge already offers. Where the two rules disagree, `dedupeSurfaces` is
the stricter and wins.

**Promote (⤢).** The pane's subject becomes the route you are on; remaining
panes stay. For a Files pane, promoting carries the whole tab strip and lands
on the tab that was showing (the route's `?tabs=` / `?compare=` params).

**Resizing.** `pane-split.ts` currently persists one percentage. It becomes a
layout array keyed by pane count (`valea.pane-split.<n>`), with the Files
pane's internal split ratio persisted separately under its own key. The count
is unambiguous because nothing is ever hidden-but-mounted: requested, mounted
and visible panes are always the same set.

## Modules

Extended:

- `lib/panes/pane-route.ts` — repeated `pane` params; `files:` and
  account-qualified `mail:` descriptors including the `|` split form; cap
  enforcement; `dedupeSurfaces` alongside `panesEqual`; promotion merge rules;
  `?all=1` alias
- `lib/panes/pane-split.ts` — per-count outer layouts
- `lib/panes/registry.ts` — entries become `PaneEntry`
  (`view` / `controls` / `createState`) instead of bare components;
  `files` → `FilesPane`, `mail` → `MailPane`, `chat` → `ChatPane`
- `lib/panes/context.ts` — `openFile` routes to a Files pane
- `lib/components/panes/PaneHost.svelte` — N panes. Its unconditional-primary
  rule is load-bearing and must survive: tearing the primary down on a pane
  change would drop the composer's draft and rejoin the session channel.
- `lib/components/shell/AppShell.svelte` — nav anchor, pane row, bar
- `lib/components/shell/IcmTree.svelte` — multiple marked rows, per-href
  `onBeforeMutate`

New:

- `lib/components/panes/FilesPane.svelte` — tab strip + content + tree; owns
  the sync and the open-file→`FileView` ref map that `onBeforeMutate(href)`
  dispatches over
- `lib/components/panes/MailPane.svelte` — the read surface (list + reader),
  consumed by both the pane registry and `/mail` itself
- `lib/components/panes/ChatPane.svelte` — sessions navigator + `ChatView`,
  holding the route logic lifted out of `routes/chat/+page.svelte`
- `lib/panes/files-pane-state.ts` — pure: the tab rules (open, close,
  activate, cap eviction, compare resolution) over a `TabState`
- `lib/panes/files-url.ts` — pure: the PRIMARY Files surface's pathname +
  `?tabs=`/`?compare=` form, both directions
- `lib/panes/auto-open.ts` — the three-step rule over tabs and the claim
- `lib/panes/pane-memory.ts` — per-route persistence and the apply rule
- `lib/shell/reveal-path.ts` — ancestor hrefs for `treeOpenState`, lifted out
  of `routes/knowledge/[...path]/+page.svelte`
- `lib/shell/pane-fit.ts` — width → how many panes and splits fit; consulted
  only when something is added or restored, never on resize
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
- `files-pane-state.test.ts` — the tab rules: `resolveTabs` dedupe/truncate/
  clamp; a tree click replaces the active tab; "open in a new tab" appends and
  evicts the oldest inactive at the cap without renumbering; closing the active
  tab lands on its neighbour; compare resolution and its fallback
- `files-url.test.ts` — the primary's URL both ways, including the two
  encoding layers a literal pipe in a filename needs
- `auto-open.test.ts` — recycles its own TAB; never evicts a user's; falls back
  to a free slot; no-ops when every tab is the user's; a user open clears the
  mark; the claim survives each removal path through the real `closeTab` and
  `dropSubject`
- `pane-memory.test.ts` — save/load; URL wins over memory; route keys are
  param-free; a `v` mismatch or unparseable descriptor is dropped and
  rewritten; storage failure degrades silently (the pattern `pane-split.ts`
  already uses)
- `pane-route.test.ts` also covers promotion: remaining panes survive, the
  promoted one is dropped, kind-specific params (`session`, `message` +
  `account`, `split`) are carried and the old primary's are not
- `reveal-path.test.ts` — ancestor href derivation, mount roots, encoded
  segments
- `pane-fit.test.ts` — thresholds at both levels; a restore too wide for the
  window truncates from the right while memory keeps the full list; resize
  alone changes nothing
- `dedupeSurfaces` cases in `pane-route.test.ts` — one surface per kind across
  primary and panes; `chat-new` allowed beside `chat`; a Files pane on
  `/knowledge` collapsed even though `primaryDescriptor` is null there
- `content-bar.test.ts` — menu subject resolution: a mount is found on Today
  with no `?icm=`; degraded and disabled mounts are skipped; Mail stays
  enabled while account status is unknown and disables only once a *loaded*
  status shows none

## Build order

One pass, internally ordered so each step is separately reviewable:

1. `pane-route.ts` — repeated params, `files:`/`mail:` descriptors, promotion
   merge rules + tests (no UI change)
2. `PaneHost` renders N panes and gains the `PaneEntry` contract
   (`view` / `controls` / `createState`); `pane-split.ts` per-count layouts.
   Panes are only ever mounted or unmounted — there is no hidden state.
3. `FilesPane` — tree + content + `files-pane-state.ts` + `reveal-path.ts`;
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

## Open items for review — all settled

*(Nothing below is outstanding. The two notes are kept as the record of how
each was decided.)*

*(Nav collapse was the last open item and is now settled: **kept**, default on,
toggled from the bar's far left. "Fixed anchor" governs the nav's position —
full height, with the bar beside it rather than under it — not whether it can
be hidden.)*
*(Stale mail panes were an open item and are now settled under Memory: any
pane whose subject vanishes closes and is dropped from storage, mail
included.)*
