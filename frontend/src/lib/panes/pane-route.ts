/**
 * Pure codec for the `?pane=` query params (composable views) — which views sit
 * beside the route's primary view. The param REPEATS: one `?pane=` per side
 * pane, in left-to-right order, capped at `PANE_CAP`. A single `?pane=` is the
 * degenerate one-pane case, so old links keep working. Same "extract the logic,
 * no component render harness" convention as `icm-route.ts`. Wire forms, with
 * the mount key and each path segment independently `encodeURIComponent`-encoded
 * (mirroring `knowledgeHref`):
 *
 *   files:<mountKey>                  (mount index, no file open)
 *   files:<mountKey>/<p1>             (one file)
 *   files:<mountKey>/<p1>|<p2>        (a split pair inside the pane)
 *   chat:<sessionId>
 *   chat:new:<mountKey>               (new-session composer scoped to that ICM;
 *                                      rewritten to chat:<id> once it starts)
 *   mail:<account>                    (mailbox list)
 *   mail:<account>/<msgId>            (one message)
 *
 * `|` is safe as the split separator because `encodeURIComponent('|') === '%7C'`,
 * so a literal pipe in a filename never collides with it.
 *
 * Invalid input parses to null — the caller renders what is left, never an error.
 */
import { encodePath, knowledgeHref } from '$lib/shell/nav';

/** How many side panes may sit beside the primary view. */
export const PANE_CAP = 2;
const SPLIT_SEP = '|';

export type FilesPaneDescriptor = { kind: 'files'; mountKey: string; paths: string[] };
export type ChatPaneDescriptor = { kind: 'chat'; sessionId: string };
export type ChatNewPaneDescriptor = { kind: 'chat-new'; mountKey: string };
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
    if (slash === -1) return { kind: 'files', mountKey, paths: [] };

    const tail = rest.slice(slash + 1);
    if (tail === '') return null;
    const rawPaths = tail.split(SPLIT_SEP);
    if (rawPaths.length > 2) return null;
    const paths = rawPaths.map(decodePath);
    if (paths.some((p) => p === null)) return null;
    return { kind: 'files', mountKey, paths: paths as string[] };
  }

  if (kind === 'chat') {
    if (rest.startsWith('new:')) {
      const mountKey = tryDecode(rest.slice('new:'.length));
      return mountKey ? { kind: 'chat-new', mountKey } : null;
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
      return `files:${mount}/${d.paths.map(encodePath).join(SPLIT_SEP)}`;
    }
    case 'chat':
      return `chat:${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `chat:new:${encodeURIComponent(d.mountKey)}`;
    case 'mail':
      return d.msgId === null
        ? `mail:${encodeURIComponent(d.account)}`
        : `mail:${encodeURIComponent(d.account)}/${encodeURIComponent(d.msgId)}`;
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

/** Legacy `?all=1`: the chat primary's sessions navigator. */
export function chatNavigatorFromUrl(url: URL): boolean {
  return url.searchParams.get('all') === '1';
}

/** The `goto` target for the current URL with the pane param set (or removed when `d` is null). Preserves every other param. */
export function withPaneParam(url: URL, d: PaneDescriptor | null): string {
  return withPanes(url, d ? [d] : []);
}

/**
 * The `?pane=…` query string to append to a SIBLING link's href — the
 * knowledge tree's file rows (`IcmTree`'s `linkSearch`), so browsing files
 * with a chat pane open keeps the pane instead of silently closing it.
 * `''` when nothing valid is open.
 *
 * Rebuilt from the PARSED descriptor rather than copied raw: a garbage
 * `?pane=` in the current URL is dropped instead of propagated onto every
 * row. Safe to concatenate — `knowledgeHref` never carries a query of its own.
 */
export function paneLinkSearch(url: URL): string {
  const d = parsePaneParam(url.searchParams.get('pane'));
  return d ? `?pane=${encodeURIComponent(serializePaneParam(d))}` : '';
}

/**
 * `href` carrying the pane `url` currently has open — for a route-level
 * navigation that must KEEP the side pane: a chat pane opening a file in the
 * primary, or the knowledge index's last-opened restore. `href`'s own query
 * (e.g. `?icm=`) survives; an invalid `?pane=` is dropped, same as
 * `paneLinkSearch`.
 */
export function hrefWithPane(href: string, url: URL): string {
  const next = new URL(href, url.origin);
  const d = parsePaneParam(url.searchParams.get('pane'));
  return withPanes(next, d ? [d] : []);
}

/** Pane-chrome title. Kept static/pure (no store lookups) — the view inside the pane carries its own richer header. */
export function paneTitle(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      return d.paths.length ? (d.paths[0].split('/').pop() ?? 'Files') : 'Files';
    case 'chat':
      return 'Chat';
    case 'chat-new':
      return 'New session';
    case 'mail':
      return 'Mail';
  }
}

/** Where the pane-chrome "open as full view" button navigates. */
export function promoteHref(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      return d.paths.length
        ? knowledgeHref(d.mountKey, d.paths[0])
        : `/knowledge?icm=${encodeURIComponent(d.mountKey)}`;
    case 'chat':
      return `/chat?session=${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `/chat?icm=${encodeURIComponent(d.mountKey)}`;
    case 'mail':
      return d.msgId === null
        ? `/mail?account=${encodeURIComponent(d.account)}`
        : `/mail?account=${encodeURIComponent(d.account)}&message=${encodeURIComponent(d.msgId)}`;
  }
}
