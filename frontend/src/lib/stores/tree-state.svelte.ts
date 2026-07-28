/**
 * Persisted file-tree expansion state (file-browser performance pass) —
 * which folder rows are open, keyed by the row's `href`
 * (`/knowledge/<mountKey>/<rel>`, so keys are already unique across
 * mounts). Folders default CLOSED: the lazy tree only fetches a folder's
 * listing when it's opened, so "everything open" would defeat the point.
 *
 * Shared by both Knowledge routes' `IcmTree` instances (one reactive
 * singleton, not per-component state) and persisted to `localStorage`
 * (`valea.tree-open`, a plain JSON array of open hrefs) so the folders a
 * user works in stay open across reloads and sessions — the "keep last
 * opened open" half of the pass; `recent-pages.ts` covers the page half.
 * Same guarded-storage posture as `recent-pages.ts`: no `localStorage`
 * (SSR, tests) just means state is session-local, never an error.
 */

const STORAGE_KEY = 'valea.tree-open';

function hasLocalStorage(): boolean {
  return typeof localStorage !== 'undefined';
}

function readStored(): string[] {
  if (!hasLocalStorage()) return [];

  let raw: string | null;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch {
    return [];
  }
  if (!raw) return [];

  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((entry): entry is string => typeof entry === 'string');
  } catch {
    return [];
  }
}

export class TreeOpenState {
  /** Only OPEN rows are kept — a closed row is simply absent (the default). */
  #open = $state<Record<string, true>>(Object.fromEntries(readStored().map((href) => [href, true])));

  isOpen(href: string): boolean {
    return this.#open[href] === true;
  }

  toggle(href: string): void {
    if (this.isOpen(href)) {
      delete this.#open[href];
    } else {
      this.#open[href] = true;
    }
    this.#persist();
  }

  /** Idempotent open — used by the routes to reveal the active page's ancestors. */
  open(href: string): void {
    if (this.isOpen(href)) return;
    this.#open[href] = true;
    this.#persist();
  }

  #persist(): void {
    if (!hasLocalStorage()) return;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(Object.keys(this.#open)));
    } catch {
      // Storage full/unavailable — expansion state just stays session-local.
    }
  }
}

export const treeOpenState = new TreeOpenState();
