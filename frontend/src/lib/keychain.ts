// This module and `updater.ts` are the ONLY modules allowed to touch
// Tauri IPC (grep-able boundary, mirrors `api/client.ts`'s header comment
// for `ash_rpc`). This one wraps the
// desktop crate's `keyring`-backed commands (mail design spec,
// §Credentials): service name = the app bundle identifier, account =
// `workspace_id:username`, where `workspace_id` is the persistent UUID
// from `config/workspace.yaml` (stable across folder moves/renames).
//
// In the browser (`bun run dev`, vitest, or any window without the Tauri
// webview bridge) every function is a documented no-op: `set` -> `false`,
// `get` -> `null`, `delete` -> resolves. None of these ever throw — callers
// (`resupplyCredential` in `stores/mail.svelte.ts`, and the future account
// setup flow) can await them unconditionally. The browser-dev credential
// path is `VALEA_MAIL_PASSWORD`, read only backend-side
// (`Valea.Mail.Engine`'s `env_credential/0`) — this module plays no part
// in it.
import { invoke } from '@tauri-apps/api/core';

/** True inside the Tauri desktop webview; false in any browser context (dev server, vitest). */
export function inDesktop(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

/**
 * Stores `secret` in the OS keychain under `workspace_id:username`.
 * Resolves `false` — never throws — in the browser, or if the underlying
 * Tauri command itself fails; callers treat both the same way (the secret
 * didn't land).
 */
export async function keychainSet(workspaceId: string, username: string, secret: string): Promise<boolean> {
  if (!inDesktop()) return false;

  try {
    await invoke('mail_secret_set', { workspaceId, username, secret });
    return true;
  } catch {
    return false;
  }
}

/**
 * Reads the stored secret. Resolves `null` — never throws — in the
 * browser, when nothing is stored, or if the underlying command fails.
 */
export async function keychainGet(workspaceId: string, username: string): Promise<string | null> {
  if (!inDesktop()) return null;

  try {
    const secret = await invoke<string | null>('mail_secret_get', { workspaceId, username });
    return secret ?? null;
  } catch {
    return null;
  }
}

/**
 * Deletes the stored secret. No-ops — never throws — in the browser or on
 * failure; a failed delete just leaves a stale entry that the next
 * `keychainSet` overwrites.
 */
export async function keychainDelete(workspaceId: string, username: string): Promise<void> {
  if (!inDesktop()) return;

  try {
    await invoke('mail_secret_delete', { workspaceId, username });
  } catch {
    // best-effort — nothing a caller can do about a keychain delete
    // failing beyond what the try/catch already contains.
  }
}
