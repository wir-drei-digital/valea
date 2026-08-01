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

Internals: an optional ICM tree at a fixed 240px, and one or two file views
sharing the remainder.

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

**AMENDMENT (2026-08-01, Daniel).** The "one implementation used by both"
claim above proved false and is retired. `/mail`'s list carries an account
switcher, debounced search, a folder picker, a read filter, pagination and a
sync footer — none of which belong in a pane, and swapping `MailPane` into the
route would have deleted all of them. What is genuinely shared is
`MessageList` + `MessageView`; `MailPane` is a third composition of them. The
real cost is the ~40-line race-suppressed selection effect, now duplicated
near-verbatim in `MailPane` and the route — and its own comments record that
the race was caught live once already. It **must be** extracted into one
`mail-selection` helper used by both — an obligation on the implementation,
not a completed fact.

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
`context.onArchived` (`FilePaneAdapter.svelte:15`); nothing in the adapter
closes anything. So `PaneHost` must supply a concrete handler to every mounted
pane.

The rule is **per subject, not per pane**: a vanished subject is removed, and
the pane closes only when it has nothing left. This matters because a Files
descriptor can name two files — closing the whole pane because one of them was
deleted would discard the other file and any pending edit in it. So a deleted
split is dropped and its sibling stays; a Files pane with no files left
survives as tree-only; a Chat or Mail pane, having one subject, closes
outright. Mail closes rather than holding a tombstone — a layout that quietly
shrinks is less alarming than one carrying a dead panel, and the message list
beside it already explains where things went.

Self-closing uses `replaceState`, so Back never steps through a pane that
immediately removes itself. Chat's existing `replacePaneWithSession` sets the
same precedent (`routes/chat/+page.svelte:241-247`).

## Width behaviour

Chat plus a Files pane with a tree and two splits needs
236 + 380 + 240 + 240 + 240 = 1336px.

**AMENDMENT (2026-08-01, Daniel): `SPLIT_MIN` is 240, not 300.** At 300 the
arithmetic put two files side by side out of reach on every laptop — a side
Files pane cleared it only at 2560px with the tree shown, or 1920px hidden,
and with the `＋ Split` control deleted there was no other route to a second
split. That contradicted one of this feature's originating asks. 240px is
narrow but genuinely readable against the 596px prose cap: it degrades rather
than blocking. When less is available, what gets
dropped is decided from the outside in — side panes right to left, so the
primary is last to give up space, and within a Files pane the second split
before the tree.

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

**AMENDMENT (2026-08-01, Daniel): there is no `＋ Split` control.** It was
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
inert. Nav collapse sits at the far left if that open item is confirmed.

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
the split it created (`autoSplit`, reset when the session changes):

1. if `autoSplit` still exists → replace **that** split
2. else if a split slot is free → open there
3. else → do nothing

So the assistant recycles its own split while a file you opened stays put —
you can pin your file on the right and let chat cycle references on the left.
Any user-initiated open into a split clears `autoSplit` for it. Rule 3 is the
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
panes stay. For a Files pane with two splits, promoting carries both (the
route's `?split=` param).

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

*(Nav collapse was the last open item and is now settled: **kept**, default on,
toggled from the bar's far left. "Fixed anchor" governs the nav's position —
full height, with the bar beside it rather than under it — not whether it can
be hidden.)*
*(Stale mail panes were an open item and are now settled under Memory: any
pane whose subject vanishes closes and is dropped from storage, mail
included.)*
