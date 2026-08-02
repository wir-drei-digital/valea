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

import { untrack } from 'svelte';

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

  /**
   * The RENDER read, and the only tracked one: every tree row's chevron and
   * children come from this, so it must stay reactive.
   */
  isOpen(href: string): boolean {
    return this.#open[href] === true;
  }

  /**
   * The same answer with no subscription, for the WRITE paths (issue #4).
   *
   * `#open` is a `$state` proxy, so reading a key here — even a key that is
   * absent — registers a dependency on it in whatever reaction is running. The
   * routes call `open()` from a standing `$effect` that reveals the active
   * document's ancestors; a tracked read on that path would enroll the effect
   * as a subscriber of the state it is writing. Collapsing a revealed folder
   * would then invalidate the effect, the effect would re-run, and it would
   * re-open the folder the user had just closed — the folder holding the open
   * document could never be collapsed.
   *
   * Untracking a read never suppresses a NOTIFICATION: writes below still wake
   * `isOpen()`'s subscribers, so the tree still redraws.
   */
  #isOpenUntracked(href: string): boolean {
    return untrack(() => this.#open[href] === true);
  }

  toggle(href: string): void {
    if (this.#isOpenUntracked(href)) {
      delete this.#open[href];
    } else {
      this.#open[href] = true;
    }
    this.#persist();
  }

  /** Idempotent open — used by the routes to reveal the active page's ancestors. */
  open(href: string): void {
    if (this.#isOpenUntracked(href)) return;
    this.#open[href] = true;
    this.#persist();
  }

  #persist(): void {
    if (!hasLocalStorage()) return;
    // The second tracking hazard on the write path, and the wider of the two:
    // `Object.keys` on a `$state` proxy is a tracked read of the whole KEY SET,
    // so a tracked persist would subscribe a caller to every open and close
    // anywhere in the tree, not just the href it touched.
    const hrefs = untrack(() => Object.keys(this.#open));
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(hrefs));
    } catch {
      // Storage full/unavailable — expansion state just stays session-local.
    }
  }
}

export const treeOpenState = new TreeOpenState();
