import type { Api } from '../api/client';
import { workspaceStore } from './workspace.svelte';

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
 *    save is already in flight — keyed off `#saving` (the promise), not the
 *    public `state`, since `state` may have been flipped to `'conflict'` by
 *    `externalChange` while the save is still outstanding — the change is
 *    remembered (`#redirtied`) rather than lost. The in-flight save's
 *    completion notices the redirty and moves to `'dirty'` (re-arming)
 *    instead of clobbering to `'clean'`/leaving `'conflict'` untouched.
 *  - The debounce timer only fires a save while still `'dirty'` — a stale
 *    timer left over from a change that was superseded by `flush()` or
 *    `resolveKeepMine()` is a no-op.
 *  - A save resolving with the `page_changed` error (the backend's optimistic
 *    concurrency guard) moves to `'conflict'`; any other error leaves the
 *    page `'dirty'` with `error` set so the next change retries.
 *  - `#generation` is `workspaceStore.generation` captured at construction
 *    (page load) — the workspace this page belongs to. `#save` compares it
 *    against the LIVE `workspaceStore.generation` before every save
 *    (debounce-fired, `flush()`, or `resolveKeepMine()`): a mismatch means
 *    the user switched workspaces (Task 21's `WorkspaceSwitcher`) while this
 *    editor instance was still alive, so the save is aborted locally —
 *    staying `'dirty'` with `error: 'workspace_changed'` — rather than
 *    silently writing this page's content into a folder that isn't the
 *    workspace it was loaded from. The captured generation is also PASSED to
 *    `saveIcmPage` so the backend's `check_generation/1` is a backstop for
 *    the narrower race this local check can't close (a switch landing after
 *    the check above but before the write reaches the backend).
 *  - `externalChange` is how the route informs the store that the page
 *    changed on disk (e.g. another window saved it, or a PubSub push):
 *    while `'clean'` it just flags `needsReload`; while `'dirty'`/`'saving'`
 *    it's a genuine conflict between the user's in-progress edit and the new
 *    disk state — UNLESS it fires while a save is in flight and turns out to
 *    be that very save's own echo (the fs-watcher noticing our own write).
 *    That's detected by remembering the hash `externalChange` saw
 *    (`#pendingExternalHash`) and comparing it, on save completion, to the
 *    hash the save itself returned: equal means echo (resolve the conflict,
 *    adopt the hash), different means a genuine foreign change (leave the
 *    conflict in place — do not clobber it back to `'clean'`).
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
  #pendingExternalHash: string | null = null;
  #generation: number | null;

  constructor(api: PageEditorApi, path: string, initial: { hash: string }, opts?: { debounceMs?: number }) {
    this.#api = api;
    this.#path = path;
    this.hash = initial.hash;
    this.#debounceMs = opts?.debounceMs ?? 1000;
    this.#generation = workspaceStore.generation;
  }

  /**
   * Records the latest getter for the page's ProseMirror JSON, marks the
   * page dirty (unless a save is in flight — in which case the redirty is
   * remembered instead, see class doc), and (re-)arms the debounce timer.
   */
  noteChange(getJson: () => object): void {
    this.#getJson = getJson;

    if (this.#saving !== null) {
      this.#redirtied = true;
    } else {
      this.state = 'dirty';
    }

    this.#armTimer();
  }

  /**
   * Cancels any pending debounce timer and saves immediately if dirty;
   * awaits an already in-flight save, looping (cancel timer, save/await)
   * for as long as the store keeps coming back dirty with a fresh in-flight
   * save — e.g. a redirty that re-armed while we were awaiting the previous
   * save. Bounded because each iteration consumes the latest JSON via
   * `#getJson`; a genuine save error stops the loop (state stays `'dirty'`
   * but `error` is set) rather than retrying forever.
   */
  async flush(): Promise<void> {
    for (;;) {
      this.#clearTimer();

      if (this.#saving) {
        await this.#saving;
        continue;
      }

      if (this.state !== 'dirty') break;

      await this.#save();

      // A genuine save failure leaves the page dirty with `error` set (see
      // `#save`) — attempt it once here (consistent with a bare dirty page
      // always getting a save attempt) but don't spin retrying it forever;
      // the next user edit (or another flush()) will try again. A redirty
      // that re-armed during a *successful* save clears `error`, so the
      // loop keeps draining those.
      if (this.error) break;
    }
  }

  /**
   * Signals that the page changed on disk out from under this store (e.g. a
   * PubSub push from another client). No-ops if the hash already matches
   * (this store's own save just landed). Otherwise: a clean page just needs
   * a reload flag so the route can refetch quietly; a dirty/saving page has
   * a genuine conflict between the in-progress edit and the new disk state —
   * unless it turns out to be the in-flight save's own echo, detected on
   * that save's completion (see `#save`).
   */
  externalChange(newHash: string): void {
    if (newHash === this.hash) return;

    if (this.state === 'clean') {
      this.needsReload = true;
    } else if (this.state === 'dirty' || this.state === 'saving') {
      if (this.#saving) {
        // Remember the hash so the in-flight save's completion can tell an
        // echo of its own write apart from a genuine foreign change.
        this.#pendingExternalHash = newHash;
      }
      this.state = 'conflict';
    }
  }

  /** Caller refetched the page after a reload signal or conflict; adopt it. */
  resolveReload(page: { hash: string; savedAt?: string }): void {
    this.#clearTimer();
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
    this.#clearTimer();
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

    // Local generation guard (see class doc) — the workspace switched out
    // from under this editor since it loaded. Abort before touching the
    // network: this page's path may not even resolve inside the NEW
    // workspace, and saving would either write to the wrong place or (with
    // no workspace open) fail anyway. Stay dirty with a surfaced error
    // rather than either silently dropping the edit or retrying forever.
    if (workspaceStore.generation !== this.#generation) {
      this.state = 'dirty';
      this.error = 'workspace_changed';
      return Promise.resolve();
    }

    this.state = 'saving';
    this.#redirtied = false;
    const getJson = this.#getJson;
    const baseHash = this.hash;
    const generation = this.#generation;

    const run = (async () => {
      try {
        const result = await this.#api.saveIcmPage(this.#path, getJson(), baseHash, generation);

        if (result.ok) {
          const data = result.data as { hash: string; savedAt: string };
          const savedHash = data.hash;

          // Was there an externalChange during this save? If so, and its
          // hash matches what we just saved, it was our own write's echo
          // (e.g. an fs-watcher noticing the file we just wrote) rather than
          // a genuine foreign change — resolve the conflict instead of
          // leaving it stuck.
          const pendingExternalHash = this.#pendingExternalHash;
          this.#pendingExternalHash = null;
          const isOwnEcho = pendingExternalHash !== null && pendingExternalHash === savedHash;

          if (this.state === 'conflict' && !isOwnEcho) {
            // A genuine foreign change arrived while we were saving. Our
            // write went through, but the on-disk state has since diverged
            // again — leave the conflict for the caller to resolve rather
            // than clobbering it back to 'clean' (and don't adopt a hash
            // that's already stale relative to that foreign change).
            return;
          }

          this.hash = savedHash;
          this.savedAt = data.savedAt;
          this.error = null;
          this.needsReload = false;

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
