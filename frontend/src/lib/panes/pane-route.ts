/**
 * Pure codec for the `?pane=` query params (composable views) — which views sit
 * beside the route's primary view. The param REPEATS: one `?pane=` per side
 * pane, in left-to-right order, capped at `PANE_CAP`. A single `?pane=` is the
 * degenerate one-pane case, so old links keep working. Same "extract the logic,
 * no component render harness" convention as `icm-route.ts`. Wire forms, with
 * the mount key and each path segment independently `encodeURIComponent`-encoded
 * (mirroring `knowledgeHref`):
 *
 *   files:<mountKey>                  (mount index, no tabs)
 *   files:<mountKey>/<p1>             (one tab, active)
 *   files:<mountKey>/<p1>|<p2>|<p3>@1 (three tabs, the second showing)
 *   files:<mountKey>/<p1>|<p2>@0+1    (compare on: tabs 0 and 1 side by side)
 *   chat:<sessionId>
 *   chat:new:<mountKey>               (new-session composer scoped to that ICM;
 *                                      rewritten to chat:<id> once it starts)
 *   chat:new:<mountKey>/<originKind>/<path>[/<mount>[/<label>]]
 *                                     (composer opened FROM a message or entry;
 *                                      every field whole-string encoded, so the
 *                                      path's own `/` cannot look like a field
 *                                      separator — unlike files:, which encodes
 *                                      per segment for readable file URLs)
 *   mail:<account>                    (mailbox list)
 *   mail:<account>/<msgId>            (one message)
 *
 * `|` is safe as the tab separator, and `@` as the cursor separator, because
 * `encodeURIComponent` escapes both (`%7C`, `%40`) — so neither can appear
 * inside an encoded path segment however a file is named.
 *
 * Invalid input parses to null — the caller renders what is left, never an error.
 * Two Files cases deliberately REPAIR instead: more than `TAB_CAP` tabs
 * truncates, and an out-of-range cursor index clamps. Both still describe
 * perfectly good subjects, and dropping the whole pane over a number would cost
 * the user every tab in it. Malformed cursor SYNTAX (`@x`, `@1+`) still fails
 * closed: a number we cannot read is not a number we may guess at.
 */
import { encodePath } from '$lib/shell/nav';
import { TAB_CAP, resolveTabs } from './files-pane-state';
import { filesPrimaryHref } from './files-url';

/** How many side panes may sit beside the primary view. */
export const PANE_CAP = 2;
const TAB_SEP = '|';
const CURSOR_SEP = '@';

export type FilesPaneDescriptor = {
  kind: 'files';
  mountKey: string;
  /** Open tabs in strip order — see `files-pane-state.ts`'s `TabState`. */
  paths: string[];
  active: number;
  compare: number | null;
};
export type ChatPaneDescriptor = { kind: 'chat'; sessionId: string };
/**
 * What a new-session composer was opened FROM. `path` is the grant-bearing
 * field (mount-relative for a Knowledge entry, workspace-relative for a mail
 * message — whichever the matching locator wants); `mount` is the
 * `mail-<slug>` key for `includeMounts`; `label` is DISPLAY ONLY.
 *
 * `label` arrives from the URL and is therefore untrusted — a shared or
 * hand-written link can carry anything. It renders as plain text, never
 * `{@html}`, and is capped by code point on BOTH parse and serialize (see
 * `capLabel`) so a long label cannot push the composer out of its pane and a
 * capped one still round-trips. Nothing is ever granted from it.
 */
export type PaneOrigin = {
  kind: 'mail-message' | 'page' | 'file';
  path: string;
  mount?: string;
  label?: string;
};

/** Display-only, URL-supplied — see `PaneOrigin.label`. */
export const ORIGIN_LABEL_CAP = 80;

export type ChatNewPaneDescriptor = {
  kind: 'chat-new';
  mountKey: string;
  from: PaneOrigin | null;
};
export type MailPaneDescriptor = { kind: 'mail'; account: string; msgId: string | null };
export type PaneDescriptor =
  | FilesPaneDescriptor
  | ChatPaneDescriptor
  | ChatNewPaneDescriptor
  | MailPaneDescriptor;

function tryDecode(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

/** Decodes one `/`-joined, per-segment-encoded path. `null` if any segment is empty or malformed. */
function decodePath(raw: string): string | null {
  if (raw === '') return null;
  const segments = raw.split('/').map(tryDecode);
  if (segments.some((s) => s === null || s === '')) return null;
  return (segments as string[]).join('/');
}

/**
 * The `@<i>` / `@<i>+<j>` cursor. `null` for anything that is not exactly one
 * index, or an index and a compare partner — the whole descriptor fails on it.
 */
function parseCursor(raw: string): { active: number; compare: number | null } | null {
  const match = /^(\d+)(?:\+(\d+))?$/.exec(raw);
  if (!match) return null;
  return { active: Number(match[1]), compare: match[2] === undefined ? null : Number(match[2]) };
}

const ORIGIN_KINDS = ['mail-message', 'page', 'file'] as const;

/**
 * The display cap, applied by CODE POINT rather than by UTF-16 code unit.
 *
 * `String.slice` cuts code units, so a label whose cap boundary falls inside a
 * surrogate pair — any non-BMP character, which for a mail subject means a
 * perfectly ordinary emoji — is left ending in a LONE HIGH SURROGATE.
 * `encodeURIComponent` THROWS `URIError` on one of those, and it throws during
 * template evaluation: `/mail` builds every row's href through
 * `hrefWithPanes` → `serializePaneParam`, so one such label takes the whole
 * message list down rather than merely spoiling a button.
 *
 * `Array.from` iterates code points, so it can never split a pair. Applied on
 * SERIALIZE as well as on parse: capping in only one direction made
 * `parse(serialize(d))` differ from `d` for any over-long label.
 */
const capLabel = (s: string): string => Array.from(s).slice(0, ORIGIN_LABEL_CAP).join('');

/** `[kind, path, mount?, label?]`, each whole-string encoded. Null if unusable. */
function parseOrigin(fields: string[]): PaneOrigin | null {
  // Its own boundary, not the caller's: `tryDecode(undefined)` returns the
  // STRING `"undefined"`, which is truthy, so a one-field origin would emit
  // `{kind: 'page', path: 'undefined'}` instead of the null this promises.
  if (fields.length < 2) return null;
  const kind = tryDecode(fields[0]);
  const path = tryDecode(fields[1]);
  if (!kind || !path) return null;
  if (!(ORIGIN_KINDS as readonly string[]).includes(kind)) return null;
  const mount = fields[2] ? tryDecode(fields[2]) : null;
  const label = fields[3] ? tryDecode(fields[3]) : null;
  if (fields[2] && mount === null) return null;
  if (fields[3] && label === null) return null;
  return {
    kind: kind as PaneOrigin['kind'],
    path,
    ...(mount ? { mount } : {}),
    ...(label ? { label: capLabel(label) } : {})
  };
}

export function parsePaneParam(raw: string | null): PaneDescriptor | null {
  if (!raw) return null;
  const colon = raw.indexOf(':');
  if (colon <= 0) return null;
  const kind = raw.slice(0, colon);
  const rest = raw.slice(colon + 1);

  if (kind === 'files') {
    const slash = rest.indexOf('/');
    const mountRaw = slash === -1 ? rest : rest.slice(0, slash);
    const mountKey = mountRaw ? tryDecode(mountRaw) : null;
    if (!mountKey) return null;
    if (slash === -1) return { kind: 'files', mountKey, paths: [], active: 0, compare: null };

    const tail = rest.slice(slash + 1);
    if (tail === '') return null;
    const parts = tail.split(CURSOR_SEP);
    // A second `@` cannot come from an encoded path, so it is a malformed
    // cursor rather than a filename — fail closed.
    if (parts.length > 2) return null;
    const cursor = parts.length === 2 ? parseCursor(parts[1]) : { active: 0, compare: null };
    if (!cursor) return null;
    const paths = parts[0].split(TAB_SEP).map(decodePath);
    if (paths.some((p) => p === null)) return null;
    // `resolveTabs` DEDUPES, and this is not tidiness. `FilesPane` keys its
    // `{#each}` on the path, so `files:life/A.md|A.md` — reachable from any
    // hand-written or shared link — is a duplicate key, which Svelte throws on
    // during render: the whole app blanks, no nav, no bar, no error page. One
    // file named twice is one file, so the honest reading is a single tab
    // rather than a refusal that would drop a perfectly good subject. It also
    // truncates past `TAB_CAP` and clamps the cursor, for the same reason.
    return {
      kind: 'files',
      mountKey,
      ...resolveTabs(paths as string[], cursor.active, cursor.compare)
    };
  }

  if (kind === 'chat') {
    if (rest.startsWith('new:')) {
      const fields = rest.slice('new:'.length).split('/');
      const mountKey = tryDecode(fields[0]);
      if (!mountKey) return null;
      if (fields.length === 1) return { kind: 'chat-new', mountKey, from: null };
      // A present-but-broken origin fails the WHOLE descriptor. It must not
      // degrade to a blank composer: a composer that opens detached while
      // looking normal is exactly the "send an instruction about an email
      // that is not attached" bug this field exists to prevent. (files:'s
      // truncate/clamp repairs do not apply — those repair a still-correct
      // subject; a broken origin has no correct subject to fall back to.)
      if (fields.length < 3 || fields.length > 5) return null;
      const from = parseOrigin(fields.slice(1));
      return from ? { kind: 'chat-new', mountKey, from } : null;
    }
    const sessionId = tryDecode(rest);
    return sessionId ? { kind: 'chat', sessionId } : null;
  }

  if (kind === 'mail') {
    const slash = rest.indexOf('/');
    const accountRaw = slash === -1 ? rest : rest.slice(0, slash);
    const account = accountRaw ? tryDecode(accountRaw) : null;
    if (!account) return null;
    if (slash === -1) return { kind: 'mail', account, msgId: null };
    const msgId = tryDecode(rest.slice(slash + 1));
    return msgId ? { kind: 'mail', account, msgId } : null;
  }

  return null;
}

export function serializePaneParam(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files': {
      const mount = encodeURIComponent(d.mountKey);
      if (d.paths.length === 0) return `files:${mount}`;
      // The cursor is omitted when it says nothing: `@0` with no compare is
      // the default, and writing it would make every one-tab URL longer than
      // the ones already in the wild for no gain.
      const cursor =
        d.compare !== null
          ? `${CURSOR_SEP}${d.active}+${d.compare}`
          : d.active === 0
            ? ''
            : `${CURSOR_SEP}${d.active}`;
      return `files:${mount}/${d.paths.slice(0, TAB_CAP).map(encodePath).join(TAB_SEP)}${cursor}`;
    }
    case 'chat':
      return `chat:${encodeURIComponent(d.sessionId)}`;
    case 'chat-new': {
      const mount = encodeURIComponent(d.mountKey);
      if (!d.from) return `chat:new:${mount}`;
      // Trailing empties are dropped; an absent mount with a present label
      // still needs its slot, so it serializes as an empty segment.
      const fields = [
        d.from.kind,
        d.from.path,
        d.from.mount ?? '',
        capLabel(d.from.label ?? '')
      ].map(encodeURIComponent);
      while (fields.length > 2 && fields[fields.length - 1] === '') fields.pop();
      return `chat:new:${mount}/${fields.join('/')}`;
    }
    case 'mail':
      return d.msgId === null
        ? `mail:${encodeURIComponent(d.account)}`
        : `mail:${encodeURIComponent(d.account)}/${encodeURIComponent(d.msgId)}`;
  }
}

/**
 * What makes a mounted pane THE SAME pane across a navigation — its SUBJECT,
 * deliberately not its contents.
 *
 * `serializePaneParam` is the wire form and carries everything: which files a
 * Files pane has open, which message a Mail pane is reading. Keying a mounted
 * pane on that string made every tree click inside a Files pane an identity
 * change, so Svelte tore the whole pane down and rebuilt it — the tree and its
 * scroll position, both `FileView`s and the per-pane state `PaneHost` holds —
 * in order to show one different file. It also made the assistant's auto-open
 * claim, which is an index living in that state, impossible to keep for longer
 * than a single open, so split recycling could never work in a pane at all.
 *
 * A different subject still is a different pane: another chat session, another
 * mailbox, another ICM. And `chat-new` -> `chat:<id>` MUST stay a change —
 * `ChatView` stashes the first prompt at mount and fires it once the session
 * exists, so the started session has to arrive on a fresh component.
 *
 * Not a substitute for `panesEqual`, which asks whether two descriptors are
 * the same thing; this asks whether one has become something else.
 */
export function paneIdentity(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      return `files:${d.mountKey}`;
    case 'chat':
      return `chat:${d.sessionId}`;
    case 'chat-new': {
      // The WHOLE origin is part of the subject, not just its path: a composer
      // opened on message A is not the same pane as one opened on message B,
      // and recycling would leave A attached while the URL says B. The same
      // path under a different kind (one entry opened as `page` and as `file`)
      // or a different mount (one message id in two mailboxes) names a
      // different subject too, so all three fields have to count. Mount and
      // path are encoded so a `:` inside either cannot borrow the separator
      // and make two different origins look like one.
      if (!d.from) return `chat-new:${d.mountKey}:`;
      const { kind, mount, path } = d.from;
      const origin = `${kind}:${encodeURIComponent(mount ?? '')}:${encodeURIComponent(path)}`;
      return `chat-new:${d.mountKey}:${origin}`;
    }
    case 'mail':
      return `mail:${d.account}`;
  }
}

/** Identity comparison. Null never equals anything, including null. */
export function panesEqual(a: PaneDescriptor | null, b: PaneDescriptor | null): boolean {
  if (!a || !b || a.kind !== b.kind) return false;
  return serializePaneParam(a) === serializePaneParam(b);
}

/**
 * One surface per descriptor kind across `[primary, ...panes]`, regardless of
 * subject. Coarser than `panesEqual` and wins where they disagree: `/knowledge`
 * has a null primary descriptor, so identity alone would let a redundant Files
 * pane through.
 */
export function dedupeSurfaces(
  primary: PaneDescriptor | null,
  panes: PaneDescriptor[]
): PaneDescriptor[] {
  const seen = new Set<string>(primary ? [primary.kind] : []);
  const out: PaneDescriptor[] = [];
  for (const pane of panes) {
    if (seen.has(pane.kind)) continue;
    seen.add(pane.kind);
    out.push(pane);
  }
  return out;
}

/** Every valid `pane` param, in document order, deduped and capped. Fails closed per entry. */
export function parsePanes(searchParams: URLSearchParams): PaneDescriptor[] {
  const parsed = searchParams
    .getAll('pane')
    .map(parsePaneParam)
    .filter((d): d is PaneDescriptor => d !== null);
  return dedupeSurfaces(null, parsed).slice(0, PANE_CAP);
}

/** `goto` target for `url` with its pane params replaced. Every other param survives. */
export function withPanes(url: URL, panes: PaneDescriptor[]): string {
  const next = new URL(url);
  next.searchParams.delete('pane');
  for (const pane of panes.slice(0, PANE_CAP)) {
    next.searchParams.append('pane', serializePaneParam(pane));
  }
  return next.pathname + next.search;
}

/**
 * `href` with the panes currently in `url` re-attached — an IN-ROUTE move that
 * keeps the composition. Renaming the page you are reading, or following a
 * deleted file back to the index, must not close the chat sitting beside it.
 *
 * Any params `href` carries of its own survive (`?tabs=`); any pane params it
 * carries are replaced, since `url`'s are the live ones.
 */
export function hrefWithPanes(href: string, url: URL): string {
  return withPanes(new URL(href, url.origin), parsePanes(url.searchParams));
}

/**
 * The `?pane=…&pane=…` suffix alone, for a component that appends a query to
 * an href it does not own (`IcmTree`'s `linkSearch`). Empty string when there
 * are no panes, so the bare href is left exactly as it was.
 */
export function paneSearchSuffix(panes: PaneDescriptor[]): string {
  const params = new URLSearchParams();
  for (const pane of panes.slice(0, PANE_CAP)) {
    params.append('pane', serializePaneParam(pane));
  }
  const search = params.toString();
  return search ? `?${search}` : '';
}

/** Legacy `?all=1`: the chat primary's sessions navigator. */
export function chatNavigatorFromUrl(url: URL): boolean {
  return url.searchParams.get('all') === '1';
}

/**
 * `/chat`'s own query shape for a new-session composer, spelled as the
 * `chat:new:` PANE param — so an origin has exactly one codec and the route
 * can never disagree with a pane about how one is written. `?icm=` alone is
 * the blank composer; `?from=` carries the origin fields verbatim.
 *
 * Null when there is no `?icm=` (nothing to compose against). A `?from=` that
 * does not parse fails the whole descriptor in `parsePaneParam` rather than
 * degrading to a blank composer — see the note there.
 */
export function chatNewParam(url: URL): string | null {
  const icm = url.searchParams.get('icm');
  if (!icm) return null;
  const from = url.searchParams.get('from');
  const mount = encodeURIComponent(icm);
  return from ? `chat:new:${mount}/${from}` : `chat:new:${mount}`;
}

/**
 * The inverse of `chatNewParam`: where a `chat-new` descriptor lives as a
 * ROUTE, origin and all.
 *
 * The origin travels as the pane param's own tail, SLICED off the serialized
 * form rather than rebuilt, so the two spellings cannot drift apart. It is
 * encoded one more time on the way into a query value because reading it back
 * with `searchParams.get` decodes once — without that extra layer a path
 * containing `%2F` would come back with a real `/` in it and split into the
 * wrong fields.
 */
export function chatNewHref(d: ChatNewPaneDescriptor): string {
  const icm = `icm=${encodeURIComponent(d.mountKey)}`;
  if (!d.from) return `/chat?${icm}`;
  // The mount key is whole-string encoded, so the first `/` is the field
  // separator and nothing before it can contain one.
  const param = serializePaneParam(d);
  return `/chat?${icm}&from=${encodeURIComponent(param.slice(param.indexOf('/') + 1))}`;
}

/** Pane-chrome title. Kept static/pure (no store lookups) — the view inside the pane carries its own richer header. */
export function paneTitle(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      // The tab strip names every open file; the pane header names the one
      // being read.
      return d.paths.length ? (d.paths[d.active]?.split('/').pop() ?? 'Files') : 'Files';
    case 'chat':
      return 'Chat';
    case 'chat-new':
      return 'New session';
    case 'mail':
      return 'Mail';
  }
}

/**
 * Where "open as full view" (⤢) navigates.
 *
 * Builds the target route with the promoted kind's OWN params, re-attaches the
 * panes that survive, and re-runs surface dedup so the promoted kind cannot
 * appear both as the new primary and beside it. The old primary's params are
 * deliberately dropped — `?session=` means nothing on `/mail`.
 */
export function promoteTarget(
  promoted: PaneDescriptor,
  url: URL,
  panes: PaneDescriptor[]
): string {
  const remaining = dedupeSurfaces(
    promoted,
    panes.filter((p) => !panesEqual(p, promoted))
  );

  const target = new URL(routeFor(promoted), url.origin);
  for (const pane of remaining.slice(0, PANE_CAP)) {
    target.searchParams.append('pane', serializePaneParam(pane));
  }
  return target.pathname + target.search;
}

function routeFor(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      // A pane with no tabs promotes to the mount INDEX rather than the mount
      // root: `＋ Pane → Files` opens a browser with nothing picked, and
      // landing on a bare folder route would be the same empty screen with the
      // index's create and doctor actions taken away.
      return d.paths.length === 0
        ? `/knowledge?icm=${encodeURIComponent(d.mountKey)}`
        : filesPrimaryHref(d.mountKey, d);
    case 'chat':
      return `/chat?session=${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      // `from` MUST travel. A composer promoted with ⤢ that dropped its
      // origin would look completely normal while being detached from the
      // message or entry it was opened from — the same bug the origin exists
      // to prevent, arriving through the maximize button instead.
      return chatNewHref(d);
    case 'mail':
      return d.msgId === null
        ? `/mail?account=${encodeURIComponent(d.account)}`
        : `/mail?account=${encodeURIComponent(d.account)}&message=${encodeURIComponent(d.msgId)}`;
  }
}
