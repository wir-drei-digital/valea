/**
 * Per-route pane memory and per-kind chrome preferences.
 *
 * The route key is the route id ALONE — never qualified by params. Which
 * session, account or mount was open is the primary's business and already
 * lives in the route; qualifying would fragment memory into hundreds of
 * entries that each restore once.
 *
 * Content lives in the URL; chrome is a preference. So which files a Files
 * pane has open travels in the descriptor, while whether its tree shows is
 * stored here and shared by every Files pane.
 *
 * Same guarded-storage posture as `pane-split.ts`: no `localStorage` (SSR,
 * tests) or a write failure just means state is session-local, never an error.
 */
import { parsePaneParam, serializePaneParam, type PaneDescriptor } from './pane-route';

const CONTENT_PREFIX = 'valea.content.';
const CHROME_KEY = 'valea.pane-chrome';
const VERSION = 1;

export type RouteKey = 'chat' | 'mail' | 'knowledge';
export type PaneChrome = { files: { tree: boolean }; chat: { sessions: boolean } };

const CHROME_DEFAULT: PaneChrome = { files: { tree: true }, chat: { sessions: false } };

export function routeKeyFor(pathname: string): RouteKey | null {
  if (pathname === '/chat' || pathname.startsWith('/chat/')) return 'chat';
  if (pathname === '/mail' || pathname.startsWith('/mail/')) return 'mail';
  if (pathname === '/knowledge' || pathname.startsWith('/knowledge/')) return 'knowledge';
  return null;
}

export function loadPanes(key: RouteKey): PaneDescriptor[] {
  try {
    const raw = localStorage.getItem(CONTENT_PREFIX + key);
    if (raw === null) return [];
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null) return [];
    const entry = parsed as { v?: unknown; panes?: unknown };
    if (entry.v !== VERSION || !Array.isArray(entry.panes)) return [];
    return entry.panes
      .map((s) => (typeof s === 'string' ? parsePaneParam(s) : null))
      .filter((d): d is PaneDescriptor => d !== null);
  } catch {
    return [];
  }
}

export function savePanes(key: RouteKey, panes: PaneDescriptor[]): void {
  try {
    localStorage.setItem(
      CONTENT_PREFIX + key,
      JSON.stringify({ v: VERSION, panes: panes.map(serializePaneParam) })
    );
  } catch {
    // best-effort persistence only
  }
}

export function loadChrome(): PaneChrome {
  try {
    const raw = localStorage.getItem(CHROME_KEY);
    if (raw === null) return CHROME_DEFAULT;
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return CHROME_DEFAULT;
    }
    const entry = parsed as Partial<PaneChrome>;
    return {
      files: { tree: entry.files?.tree ?? CHROME_DEFAULT.files.tree },
      chat: { sessions: entry.chat?.sessions ?? CHROME_DEFAULT.chat.sessions }
    };
  } catch {
    return CHROME_DEFAULT;
  }
}

export function saveChrome(chrome: PaneChrome): void {
  try {
    localStorage.setItem(CHROME_KEY, JSON.stringify(chrome));
  } catch {
    // best-effort persistence only
  }
}
