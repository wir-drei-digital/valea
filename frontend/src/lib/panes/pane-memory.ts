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
import { truncateToFit } from '$lib/shell/pane-fit';
import {
  dedupeSurfaces,
  parsePaneParam,
  serializePaneParam,
  type PaneDescriptor
} from './pane-route';

const CONTENT_PREFIX = 'valea.content.';
const CHROME_KEY = 'valea.pane-chrome';
const NAV_KEY = 'valea.nav-visible';
const VERSION = 1;

export type RouteKey = 'chat' | 'mail' | 'knowledge';
export type PaneChrome = { files: { tree: boolean }; chat: { sessions: boolean } };

/**
 * Deep-frozen, and never handed out directly — `defaultChrome()` builds a
 * fresh literal for every caller. `let chrome = $state(loadChrome())` followed
 * by a toggle is the obvious call site, and returning this object would let
 * that toggle rewrite the shipped default for the life of the process: a fresh
 * profile, an SSR render or a cleared storage would then load the wrong one,
 * and a long-lived Tauri process never restarts to heal it. The freeze makes a
 * future regression throw instead of quietly corrupting.
 */
const CHROME_DEFAULT: PaneChrome = Object.freeze({
  files: Object.freeze({ tree: true }),
  chat: Object.freeze({ sessions: false })
});

function defaultChrome(): PaneChrome {
  return {
    files: { tree: CHROME_DEFAULT.files.tree },
    chat: { sessions: CHROME_DEFAULT.chat.sessions }
  };
}

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

/**
 * What a route entry should put beside its primary, given what the URL says
 * and what this route remembers. `null` means "leave the URL alone".
 *
 * Memory applies ONLY when the URL names no panes. A URL carrying `pane`
 * always wins, so a link shared between two people is never rewritten by the
 * recipient's own habits — and, just as importantly, a composition someone
 * navigated to on purpose is never quietly replaced by an older one.
 *
 * Deduped BEFORE it is truncated, not after. The other order loses panes for
 * no reason: remembering `[chat, files]` on a route whose primary is already a
 * chat, at a width with room for one pane, truncates to `[chat]` and then
 * dedupes it away — restoring nothing, when the files pane both fitted and
 * belonged.
 *
 * What is restored is truncated to what FITS while the stored row keeps every
 * pane, so a composition too wide for today's window comes back on a wider one
 * tomorrow. That is why the caller must not write the truncated row back.
 *
 * An unmeasured window restores nothing rather than guessing: `panesThatFit`
 * returns NaN for a NaN width (`spare < 0` is false for NaN), and a NaN pane
 * count is a silent "no room" at best.
 */
export function restoreTarget(input: {
  /** Whether the URL carries at least one `pane` param. */
  urlNamesPanes: boolean;
  remembered: PaneDescriptor[];
  /** The route's own primary surface, so a restore cannot duplicate it. */
  primary: PaneDescriptor | null;
  windowWidth: number | undefined;
  navVisible: boolean;
}): PaneDescriptor[] | null {
  if (input.urlNamesPanes) return null;
  if (typeof input.windowWidth !== 'number' || !Number.isFinite(input.windowWidth)) return null;
  const fitted = truncateToFit(
    dedupeSurfaces(input.primary, input.remembered),
    input.windowWidth,
    input.navVisible
  );
  return fitted.length > 0 ? fitted : null;
}

export function loadChrome(): PaneChrome {
  try {
    const raw = localStorage.getItem(CHROME_KEY);
    if (raw === null) return defaultChrome();
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return defaultChrome();
    }
    const entry = parsed as Partial<PaneChrome>;
    return {
      files: { tree: entry.files?.tree ?? CHROME_DEFAULT.files.tree },
      chat: { sessions: entry.chat?.sessions ?? CHROME_DEFAULT.chat.sessions }
    };
  } catch {
    return defaultChrome();
  }
}

export function saveChrome(chrome: PaneChrome): void {
  try {
    localStorage.setItem(CHROME_KEY, JSON.stringify(chrome));
  } catch {
    // best-effort persistence only
  }
}

/**
 * Whether the left nav is showing. **Default true** — the nav is the app's
 * only way between routes, so an unreadable or absent entry must never hide
 * it; only an explicit `'0'` does.
 *
 * It is stored rather than held in component state because every route mounts
 * its own `AppShell`: a collapse held in memory would spring back open on the
 * next navigation, one click after the user asked for the width.
 *
 * Its own key rather than a field on `PaneChrome`: the nav belongs to the
 * SHELL, not to a pane kind, and `loadChrome`'s shape is what a Files or Chat
 * pane reads.
 */
export function loadNavVisible(): boolean {
  try {
    return localStorage.getItem(NAV_KEY) !== '0';
  } catch {
    return true;
  }
}

export function saveNavVisible(visible: boolean): void {
  try {
    localStorage.setItem(NAV_KEY, visible ? '1' : '0');
  } catch {
    // best-effort persistence only
  }
}
