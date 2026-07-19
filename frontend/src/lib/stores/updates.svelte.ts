import {
  checkForUpdate,
  relaunchApp,
  updatesSupported,
  type PendingUpdate,
  type UpdateCheck
} from '$lib/updater';

/**
 * What the sidebar's `UpdateNotice` renders. `idle` covers everything with
 * nothing to say: unsupported contexts (browser, `tauri dev`), an
 * up-to-date app, and failed *checks* — a check failure with no pending
 * update is silence, not a nag (offline is normal for a local-first app);
 * the 6-hourly re-check is the retry. Only failures of an actual download/
 * install surface as `error`.
 */
export type UpdatePhase =
  | { kind: 'idle' }
  | { kind: 'checking' }
  | { kind: 'downloading'; version: string; downloaded: number; total: number | null }
  | { kind: 'ready'; version: string }
  | { kind: 'installing'; version: string }
  /** `retriable` gates the card's "Try again" — false for the one terminal case (installed, relaunch refused). */
  | { kind: 'error'; message: string; retriable: boolean };

/** Minimal surface of `$lib/updater` this store depends on — lets tests inject fakes. */
type UpdaterSurface = {
  updatesSupported: typeof updatesSupported;
  checkForUpdate: typeof checkForUpdate;
  relaunchApp: typeof relaunchApp;
};

/** First check waits out the workspace bootstrap + sidecar warm-up. */
export const FIRST_CHECK_DELAY_MS = 90_000;
/** Long-running instances re-check twice a shift, roughly. */
export const RECHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;

/**
 * Auto-update state machine: check → auto-download → ready → (user click)
 * install + relaunch. Wired once from the root layout's `onMount` via
 * `start()`; every phase is rendered exclusively by
 * `shell/UpdateNotice.svelte` at the bottom of the sidebar.
 */
export class UpdatesStore {
  phase: UpdatePhase = $state({ kind: 'idle' });

  #updater: UpdaterSurface;
  #pending: PendingUpdate | null = null;
  #started = false;
  #timer: ReturnType<typeof setInterval> | null = null;

  constructor(updater: UpdaterSurface) {
    this.#updater = updater;
  }

  /**
   * Schedules the boot check + periodic re-checks. No-op in contexts where
   * updates can't apply, and idempotent — the root layout is the only
   * intended caller, but a second call must not double the timers.
   */
  start(): void {
    if (this.#started || !this.#updater.updatesSupported()) return;
    this.#started = true;

    setTimeout(() => void this.check(), FIRST_CHECK_DELAY_MS);
    this.#timer = setInterval(() => void this.check(), RECHECK_INTERVAL_MS);
  }

  /** Tears the timers down (tests; the root layout never unmounts). */
  stop(): void {
    if (this.#timer !== null) clearInterval(this.#timer);
    this.#timer = null;
    this.#started = false;
  }

  /**
   * One check → auto-download pass. Skips itself whenever a cycle is
   * already underway (the interval firing mid-download must not restart
   * it); an `error` phase is retriable, so a scheduled re-check doubles as
   * background recovery.
   */
  async check(): Promise<void> {
    if (this.phase.kind !== 'idle' && this.phase.kind !== 'error') return;

    this.phase = { kind: 'checking' };
    const result: UpdateCheck = await this.#updater.checkForUpdate();

    switch (result.outcome) {
      case 'unsupported':
      case 'none':
        this.phase = { kind: 'idle' };
        return;
      case 'error':
        // No pending update was harmed: stay quiet (see UpdatePhase doc).
        console.debug('[updates] check failed:', result.message);
        this.phase = { kind: 'idle' };
        return;
      case 'available':
        this.#pending = result.update;
        await this.#download(result.update);
    }
  }

  /** "Try again" on the error card — a fresh cycle re-finds the update and re-downloads. */
  retry(): void {
    void this.check();
  }

  /**
   * The notice's "Restart to update" click. Install failures surface on the
   * card; a relaunch failure after a successful install is terminal-but-
   * harmless (the new version runs on next manual start), stated as such
   * rather than offering a retry that would re-install over itself.
   */
  async installAndRelaunch(): Promise<void> {
    if (this.phase.kind !== 'ready' || this.#pending === null) return;

    const version = this.phase.version;
    this.phase = { kind: 'installing', version };

    if (!(await this.#pending.install())) {
      this.phase = { kind: 'error', message: 'The update could not be installed.', retriable: true };
      return;
    }

    this.#pending = null;
    if (!(await this.#updater.relaunchApp())) {
      this.phase = {
        kind: 'error',
        message: 'Update installed — quit and reopen Valea to finish.',
        retriable: false
      };
    }
  }

  async #download(update: PendingUpdate): Promise<void> {
    this.phase = { kind: 'downloading', version: update.version, downloaded: 0, total: null };

    const ok = await update.download((downloaded, total) => {
      if (this.phase.kind === 'downloading') {
        this.phase = { kind: 'downloading', version: update.version, downloaded, total };
      }
    });

    if (ok) {
      this.phase = { kind: 'ready', version: update.version };
    } else {
      this.#pending = null;
      this.phase = { kind: 'error', message: 'The update could not be downloaded.', retriable: true };
    }
  }
}

export const updatesStore = new UpdatesStore({ updatesSupported, checkForUpdate, relaunchApp });
