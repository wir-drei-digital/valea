/**
 * Pure codec for the `?pane=` query param (side-panes pass) — which view is
 * open in the side pane next to the route's primary view. Same
 * "extract the logic, no component render harness" convention as
 * `icm-route.ts`. Wire forms:
 *
 *   file:<mountKey>/<relPath>   (mountKey and each path segment URL-encoded,
 *                                mirroring `knowledgeHref`)
 *   chat:<sessionId>
 *   chat:new:<mountKey>         (new-session composer scoped to that ICM;
 *                                rewritten to chat:<id> once the session starts)
 *
 * Invalid input parses to null — the caller renders the primary alone.
 */
import { encodePath, knowledgeHref } from '$lib/shell/nav';

export type FilePaneDescriptor = { kind: 'file'; mountKey: string; path: string };
export type ChatPaneDescriptor = { kind: 'chat'; sessionId: string };
export type ChatNewPaneDescriptor = { kind: 'chat-new'; mountKey: string };
export type PaneDescriptor = FilePaneDescriptor | ChatPaneDescriptor | ChatNewPaneDescriptor;

function tryDecode(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

export function parsePaneParam(raw: string | null): PaneDescriptor | null {
  if (!raw) return null;
  const colon = raw.indexOf(':');
  if (colon <= 0) return null;
  const kind = raw.slice(0, colon);
  const rest = raw.slice(colon + 1);

  if (kind === 'file') {
    const slash = rest.indexOf('/');
    if (slash <= 0 || slash === rest.length - 1) return null;
    const mountKey = tryDecode(rest.slice(0, slash));
    if (!mountKey) return null;
    const segments = rest.slice(slash + 1).split('/').map(tryDecode);
    if (segments.some((s) => s === null || s === '')) return null;
    return { kind: 'file', mountKey, path: (segments as string[]).join('/') };
  }

  if (kind === 'chat') {
    if (rest.startsWith('new:')) {
      const mountKey = tryDecode(rest.slice('new:'.length));
      return mountKey ? { kind: 'chat-new', mountKey } : null;
    }
    const sessionId = tryDecode(rest);
    return sessionId ? { kind: 'chat', sessionId } : null;
  }

  return null;
}

export function serializePaneParam(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'file':
      return `file:${encodeURIComponent(d.mountKey)}/${encodePath(d.path)}`;
    case 'chat':
      return `chat:${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `chat:new:${encodeURIComponent(d.mountKey)}`;
  }
}

/** Identity comparison — used to reject a side pane duplicating the primary view. Null never equals anything (including null). */
export function panesEqual(a: PaneDescriptor | null, b: PaneDescriptor | null): boolean {
  if (!a || !b || a.kind !== b.kind) return false;
  switch (a.kind) {
    case 'file':
      return b.kind === 'file' && a.mountKey === b.mountKey && a.path === b.path;
    case 'chat':
      return b.kind === 'chat' && a.sessionId === b.sessionId;
    case 'chat-new':
      return b.kind === 'chat-new' && a.mountKey === b.mountKey;
  }
}

/** The `goto` target for the current URL with the pane param set (or removed when `d` is null). Preserves every other param. */
export function withPaneParam(url: URL, d: PaneDescriptor | null): string {
  const next = new URL(url);
  if (d) next.searchParams.set('pane', serializePaneParam(d));
  else next.searchParams.delete('pane');
  return next.pathname + next.search;
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
  if (d) next.searchParams.set('pane', serializePaneParam(d));
  return next.pathname + next.search;
}

/** Pane-chrome title. Kept static/pure (no store lookups) — the view inside the pane carries its own richer header. */
export function paneTitle(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'file':
      return d.path.split('/').pop() ?? d.path;
    case 'chat':
      return 'Chat';
    case 'chat-new':
      return 'New session';
  }
}

/** Where the pane-chrome "open as full view" button navigates. */
export function promoteHref(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'file':
      return knowledgeHref(d.mountKey, d.path);
    case 'chat':
      return `/chat?session=${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `/chat?icm=${encodeURIComponent(d.mountKey)}`;
  }
}
