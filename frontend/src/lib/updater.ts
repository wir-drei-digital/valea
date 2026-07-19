// This module and `keychain.ts` are the ONLY modules allowed to touch
// Tauri IPC (grep-able boundary, mirrors `api/client.ts`'s header comment
// for `ash_rpc`). It wraps the updater/process plugins behind the same
// contract keychain.ts established: in the browser (`bun run dev`, vitest,
// any window without the Tauri webview bridge) every function is a
// documented no-op, and nothing here ever throws — failures come back as
// values so `stores/updates.svelte.ts` (the only caller) can render them.
//
// The desktop updater flow these wrap: `check()` hits the endpoints in
// desktop/src-tauri/tauri.conf.json (`plugins.updater`), signature-verifies
// against the pubkey baked in there, and `install()` swaps the app bundle;
// `relaunch()` exits through the normal Tauri run loop — main.rs's
// RunEvent::Exit handler kills the sidecar — and starts the new version.
import { check, type Update } from '@tauri-apps/plugin-updater';
import { relaunch } from '@tauri-apps/plugin-process';
import { inDesktop } from '$lib/keychain';

/**
 * True only where an update can actually be applied: the packaged desktop
 * app. `tauri dev` and the browser dev server are excluded — a debug shell
 * reports the placeholder version and would forever "offer" the latest
 * release, and the browser has no bridge at all.
 */
export function updatesSupported(): boolean {
  return inDesktop() && import.meta.env.PROD;
}

/**
 * A found update, held so `download` and `install` operate on the same
 * underlying plugin object. `version` is the raw semver from latest.json
 * (no `v` prefix) — UI adds its own prefix.
 */
export interface PendingUpdate {
  version: string;
  /**
   * Streams the update artifact. `onProgress(downloaded, total)` fires per
   * chunk; `total` is `null` when the server sent no content length.
   * Resolves `false` — never throws — on any download failure.
   */
  download(onProgress: (downloaded: number, total: number | null) => void): Promise<boolean>;
  /**
   * Applies an already-downloaded update. Resolves `false` — never throws —
   * on failure. The new version runs only after a relaunch.
   */
  install(): Promise<boolean>;
}

export type UpdateCheck =
  /** Browser or dev build — there is nothing to check against. */
  | { outcome: 'unsupported' }
  /** The running version is current (or the release had no artifact for this platform). */
  | { outcome: 'none' }
  | { outcome: 'available'; update: PendingUpdate }
  /** Check itself failed — offline, endpoint unreachable, bad manifest. */
  | { outcome: 'error'; message: string };

/** Asks the release endpoint whether a newer signed build exists. */
export async function checkForUpdate(): Promise<UpdateCheck> {
  if (!updatesSupported()) return { outcome: 'unsupported' };

  try {
    const update = await check();
    if (!update) return { outcome: 'none' };
    return { outcome: 'available', update: wrap(update) };
  } catch (error) {
    return { outcome: 'error', message: describe(error) };
  }
}

/**
 * Restarts the app so an installed update takes effect. Resolves `false` —
 * never throws — if the relaunch could not be requested (in which case the
 * old version simply keeps running until the user quits).
 */
export async function relaunchApp(): Promise<boolean> {
  if (!inDesktop()) return false;

  try {
    await relaunch();
    return true;
  } catch {
    return false;
  }
}

function wrap(update: Update): PendingUpdate {
  return {
    version: update.version,
    async download(onProgress) {
      try {
        let downloaded = 0;
        let total: number | null = null;
        await update.download((event) => {
          if (event.event === 'Started') {
            total = event.data.contentLength ?? null;
          } else if (event.event === 'Progress') {
            downloaded += event.data.chunkLength;
            onProgress(downloaded, total);
          }
        });
        return true;
      } catch {
        return false;
      }
    },
    async install() {
      try {
        await update.install();
        return true;
      } catch {
        return false;
      }
    }
  };
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message;
  return typeof error === 'string' ? error : 'update check failed';
}
