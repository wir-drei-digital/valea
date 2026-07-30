# Message File Links — Clickable Paths in Agent Prose + Single-Hit Auto-Open

**Date:** 2026-07-30
**Status:** Approved (design), pending implementation plan

## Goal

When the agent answers with a file path in prose — the common "I searched,
here is the file" reply that never triggers a read tool call — the path
should be actionable, not dead text:

1. **Clickable codespans.** An inline codespan that looks like an in-mount
   relative file path renders as a button opening that file in the side
   pane, with the same backend-validated open path the tool-card chips use.
2. **Clickable backticked URLs.** A codespan whose text passes the existing
   `safeLinkHref` vetting renders as an external link — that check admits
   http(s) AND `mailto:`, and reusing it verbatim is deliberate: one shared
   definition of "linkable" (bare URLs in plain prose are already
   autolinked by marked's GFM rules and need no work).
3. **Single-hit auto-open.** When a live turn ends and the agent's final
   message mentions exactly one distinct openable path, that file opens in
   the pane automatically — but only after a backend existence check, only
   when no pane is already open, and never when reopening an old session.

Explicitly **not** in scope: linkifying bare paths outside backticks,
client-side relativization of absolute paths, thought items, fenced code
blocks, and any backend changes (`icm_paths_exist` already exists).

## Architecture

### 1. Path/URL detection — pure helpers in `agent-markdown.ts`

New functions beside `safeLinkHref` (same "which tokens earn an affordance"
family), unit-tested in `agent-markdown.test.ts`:

```
codespanFilePath(text: string): string | undefined
```

Returns the openable relPath when the codespan text is path-shaped, else
undefined. Input is the DECODED codespan text: marked pre-escapes codespan
token text (`&amp;` for `&`, …), and the renderer already displays it
through `unescapeMarked` — detection and the opened path must run on that
same decoded string, so what opens is exactly what the user sees. Rules:

- Strip one optional trailing `:NN` line suffix (`CONTEXT.md:22`) — the
  returned relPath drops it (pane opens have no line targeting today).
- Reject: absolute paths (leading `/` or `~`), scheme-ish strings
  (`[a-z]+://`), any `..` segment, trailing `/` (directories), backticks,
  parentheses, control characters, length > 256.
- Require the basename to end in an extension: `\.[A-Za-z][A-Za-z0-9]{0,7}$`
  (`today.json` yes, `v1.2` no, bare `.md` no, extensionless `README` no —
  accepted miss).
- Whitespace is rejected unless the string contains a `/` — so
  `clients/Mara Lindt/notes.md` qualifies but a backticked sentence never
  does.

```
messageFilePaths(text: string): string[]
```

Lexes the message (`lexAgentMarkdown`) and walks the full token tree,
returning the **distinct** `codespanFilePath` hits across all inline
codespans. Fenced `code` blocks are not descended into. Used only by
auto-open.

URL codespans need no new helper: the render branch calls the existing
`safeLinkHref` on the codespan text.

### 2. Rendering — `MarkdownInline.svelte` codespan branch

`onOpenFile?: (relPath: string) => void` threads Transcript → MessageItem →
MarkdownBlocks → MarkdownInline (both recursive components pass it through
all self-recursions: lists, blockquotes, tables, nested inline tokens).
It is the same handler the tool-card chips receive (`openToolFile` in
ChatView), so a click only feeds the `?pane=` codec and the backend keeps
owning containment. `{@html}` stays forbidden; all text still reaches the
DOM through plain interpolation.

Codespan branch, in order:

1. `safeLinkHref(text)` passes → render an `<a>` with codespan styling
   (mono, `bg-paper-track`) plus the link affordance (underline, hover),
   routed through the existing desktop-aware `onLinkClick`/`openExternal`.
2. `codespanFilePath(text)` hits AND `onOpenFile` present → render a
   `<button>` keeping the codespan look with a hover affordance consistent
   with the chips (`hover:bg-paper-pill`), `aria-label` "Open <relPath>",
   clicking calls `onOpenFile(relPath)` (the `:NN`-stripped path).
3. Otherwise → today's plain `<code>`.

User messages, thought items, and code blocks are untouched. Because this
is the shared renderer, reopened transcripts gain the affordance
retroactively.

### 3. Auto-open — ChatView effect

State per attached store. The reset-on-store-swap bookkeeping mirrors the
file-activity rail's, but the baseline is the OPPOSITE of the rail's: the
rail deliberately fires on a populated attach snapshot (its baseline is 0),
while auto-open must never fire from history — its baseline is the count of
`turn` items already present at attach.

- Baseline = count of `turn` items at attach. History never fires.
- When the count increments live and the new turn item's `stop_reason` is
  `end_turn` (error/cancel turns carry other values and never fire): take
  the final assistant `message` item preceding that turn item, compute
  `messageFilePaths(text)`.
- Fire only when ALL hold:
  - exactly one distinct candidate path;
  - ChatView is the primary view (a pane-hosted ChatView never spawns
    panes) and `openToolFile` is available (mount known);
  - no side pane is currently open (never replace what the user is
    viewing). `PaneContext` exposes no pane state today, so it gains an
    optional `hasOpenPane?: () => boolean` callback that the `/chat` route
    wires from its own `paneDescriptor`; per the context contract views
    tolerate absent callbacks — an absent one means "unknown", and
    auto-open conservatively does not fire;
  - `icmPathsExist(["<MountSummary.root>/<relPath>"])` returns
    `exists: true` — `icm_paths_exist` attributes each path by ABSOLUTE
    mount-root prefix (`Valea.Api.ICM.find_mount/2` matches the path
    string as given, before any workspace anchoring), so the payload must
    be the mount's resolved root joined with the relPath; non-mount paths
    are simply `false`. (`MarkdownPageView`'s dangling-link check sends
    mount-relative paths to this RPC — a pre-existing defect, tracked
    separately.)
  - stale guard: capture the store reference and turn-item count before the
    `await`, re-check both after it resolves, drop the result on any change
    (same captured-before-await shape as `MarkdownPageView.refreshDangling`
    — this covers a queued prompt starting the next turn mid-flight).
- Then `openToolFile(relPath)`. At most one auto-open per turn end. If the
  user closes the pane, a later turn may open one again — each turn end is
  a fresh signal.

Auto-open considers file paths only. URLs (bare or backticked) are never
opened automatically — external navigation stays a deliberate click.

The turn-gating + candidate selection logic lives in a pure helper over
`AcpItemLike[]` (item-shapes or a sibling module) so it is unit-testable
without a component harness; the effect just wires it to the RPC and
`openToolFile`.

## Security

- Every new affordance hands an untrusted agent-authored string to an
  existing backend-validated codec: `?pane=` file opens (containment) or
  `safeLinkHref`-vetted external links. No new trust is granted.
- Auto-open lets the agent cause at most one visible, reversible pane open
  per turn, of an in-mount file only, gated on real existence. It cannot
  navigate outside mounts, cannot fire from history replay, and cannot
  displace an open pane.
- `icm_paths_exist` calls are batched (one per qualifying turn end, one
  path) — no per-message chatter, nothing on transcript attach.

## Testing

- Unit: `codespanFilePath` accept/reject table (line suffixes, spaces with
  and without slash, traversal, absolute, URL-ish, extension rules);
  `messageFilePaths` distinctness + fenced-block exclusion; the turn-gating
  helper (baseline, non-`end_turn` stops, multi-path messages, no-message
  turns).
- Browser verification is a MANUAL pass via the fake-adapter rig (the repo
  has no automated browser framework): extend the `slow` scenario's final
  message to mention exactly one backticked in-mount path (e.g.
  `CONTEXT.md`) and one backticked URL — one run then proves the file chip,
  the URL link, and the live auto-open; reopening the same session proves
  history never fires.
- `svelte-check` and the full vitest suite stay green.
