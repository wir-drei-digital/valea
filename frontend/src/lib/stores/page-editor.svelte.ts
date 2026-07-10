import type { Api } from '../api/client';

export type PageEditorState = 'clean' | 'dirty' | 'saving' | 'conflict';

/**
 * Minimal surface of `api` this store depends on — mirrors the
 * `workspace.svelte.ts` convention of a `Pick<Api, ...>` so tests can inject
 * a fake without implementing every wrapped call.
 */
type PageEditorApi = Pick<Api, 'saveIcmPage' | 'icmPage'>;

/**
 * Save-loop state machine for one open ICM page. One instance per open page,
 * created by the route (no module-level singleton — see `workspaceStore` /
 * `icmStore` for the singleton pattern this deliberately does NOT follow,
 * since multiple pages may be edited across navigations).
 *
 * State transitions:
 *  - `noteChange` marks the page dirty and (re-)arms a debounce timer. If a
 *    save is already in flight, the change is remembered (`#redirtied`)
 *    rather than lost — the in-flight save's completion notices the redirty
 *    and moves to `'dirty'` (re-arming) instead of `'clean'`.
 *  - The debounce timer only fires a save while still `'dirty'` — a stale
 *    timer left over from a change that was superseded by `flush()` or
 *    `resolveKeepMine()` is a no-op.
 *  - A save resolving with the `page_changed` error (the backend's optimistic
 *    concurrency guard) moves to `'conflict'`; any other error leaves the
 *    page `'dirty'` with `error` set so the next change retries.
 *  - `externalChange` is how the route informs the store that the page
 *    changed on disk (e.g. another window saved it, or a PubSub push):
 *    while `'clean'` it just flags `needsReload`; while `'dirty'`/`'saving'`
 *    it's a genuine conflict between the user's in-progress edit and the new
 *    disk state.
 */
export class PageEditorStore {
  state: PageEditorState = $state('clean');
  hash: string = $state('');
  savedAt: string | null = $state(null);
  error: string | null = $state(null);
  needsReload: boolean = $state(false);

  #api: PageEditorApi;
  #path: string;
  #debounceMs: number;
  #timer: ReturnType<typeof setTimeout> | null = null;
  #getJson: (() => object) | null = null;
  #saving: Promise<void> | null = null;
  #redirtied = false;

  constructor(api: PageEditorApi, path: string, initial: { hash: string }, opts?: { debounceMs?: number }) {
    this.#api = api;
    this.#path = path;
    this.hash = initial.hash;
    this.#debounceMs = opts?.debounceMs ?? 1000;
  }

  /**
   * Records the latest getter for the page's ProseMirror JSON, marks the
   * page dirty (unless a save is in flight — in which case the redirty is
   * remembered instead, see class doc), and (re-)arms the debounce timer.
   */
  noteChange(getJson: () => object): void {
    this.#getJson = getJson;

    if (this.state === 'saving') {
      this.#redirtied = true;
    } else {
      this.state = 'dirty';
    }

    this.#armTimer();
  }

  /**
   * Cancels any pending debounce timer and saves immediately if dirty;
   * awaits an already in-flight save (and, if that save's completion
   * re-armed because of a redirty, saves again) so the returned promise only
   * resolves once nothing is left unsaved.
   */
  async flush(): Promise<void> {
    this.#clearTimer();

    if (this.#saving) {
      await this.#saving;
    }

    this.#clearTimer();

    if (this.state === 'dirty') {
      await this.#save();
    }
  }

  /**
   * Signals that the page changed on disk out from under this store (e.g. a
   * PubSub push from another client). No-ops if the hash already matches
   * (this store's own save just landed). Otherwise: a clean page just needs
   * a reload flag so the route can refetch quietly; a dirty/saving page has
   * a genuine conflict between the in-progress edit and the new disk state.
   */
  externalChange(newHash: string): void {
    if (newHash === this.hash) return;

    if (this.state === 'clean') {
      this.needsReload = true;
    } else if (this.state === 'dirty' || this.state === 'saving') {
      this.state = 'conflict';
    }
  }

  /** Caller refetched the page after a reload signal or conflict; adopt it. */
  resolveReload(page: { hash: string; savedAt?: string }): void {
    this.hash = page.hash;
    if (page.savedAt !== undefined) this.savedAt = page.savedAt;
    this.needsReload = false;
    this.error = null;
    this.state = 'clean';
  }

  /**
   * Conflict resolution: keep the user's in-progress edit. Refetches the
   * current on-disk hash (without touching content) so the subsequent save
   * carries a fresh `baseHash`, then saves the user's own JSON on top.
   */
  async resolveKeepMine(): Promise<void> {
    const result = await this.#api.icmPage(this.#path);
    if (result.ok) {
      const data = result.data as { hash: string };
      this.hash = data.hash;
    }
    this.error = null;
    await this.#save();
  }

  #clearTimer(): void {
    if (this.#timer) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
  }

  #armTimer(): void {
    this.#clearTimer();
    this.#timer = setTimeout(() => {
      this.#timer = null;
      // Guard against a stale timer firing after `flush()` or
      // `resolveKeepMine()` already saved/resolved the page out from under
      // it — only a still-dirty page should trigger a save here.
      if (this.state === 'dirty') {
        void this.#save();
      }
    }, this.#debounceMs);
  }

  /**
   * Performs (or joins) the actual save. Memoized on `#saving` so concurrent
   * callers (a firing timer racing `flush()`, `flush()` called twice, etc.)
   * share one in-flight request rather than double-saving.
   */
  #save(): Promise<void> {
    if (this.#saving) return this.#saving;
    if (!this.#getJson) return Promise.resolve();

    this.state = 'saving';
    this.#redirtied = false;
    const getJson = this.#getJson;
    const baseHash = this.hash;

    const run = (async () => {
      try {
        const result = await this.#api.saveIcmPage(this.#path, getJson(), baseHash);

        if (result.ok) {
          const data = result.data as { hash: string; savedAt: string };
          this.hash = data.hash;
          this.savedAt = data.savedAt;
          this.error = null;

          if (this.#redirtied) {
            // A change arrived while this save was in flight — don't mark
            // clean, and re-arm so the redirtied edit still gets saved.
            this.#redirtied = false;
            this.state = 'dirty';
            this.#armTimer();
          } else {
            this.state = 'clean';
          }
        } else if (result.error === 'page_changed') {
          this.state = 'conflict';
          this.error = result.error;
        } else {
          this.state = 'dirty';
          this.error = result.error;
        }
      } finally {
        this.#saving = null;
      }
    })();

    this.#saving = run;
    return run;
  }
}
