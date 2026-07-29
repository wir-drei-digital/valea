// This module, `keychain.ts`, `updater.ts`, and `shell/external-link.ts` are
// the ONLY modules allowed to touch Tauri IPC (grep-able boundary, mirrors
// `api/client.ts`'s header comment for `ash_rpc`). It wraps the notification
// plugin behind the same contract keychain.ts established: nothing here ever
// throws, failures come back as values, and the browser is a real supported
// environment rather than a degraded one.
//
// TWO backends, one contract (`inDesktop()` picks, exactly as keychain.ts
// does):
//
//   * DESKTOP — `@tauri-apps/plugin-notification`. Registered in the desktop
//     crate (`main.rs`, `tauri_plugin_notification::init()`) and gated by
//     `desktop/src-tauri/capabilities/notifications.json`, which grants only
//     `is-permission-granted` / `request-permission` / `notify` to the main
//     window. Without that capability file every call below rejects and this
//     module reports "not granted" — it does not crash the caller.
//   * BROWSER (`bun run dev`, vitest, any window with no Tauri bridge) — the
//     standard `Notification` API. A window without it (vitest's default
//     environment) reads as permanently denied.
//
// The permission is requested LAZILY — only from `requestNotifyPermission`,
// which the settings toggle calls the first time a user turns notifications
// on. Nothing here asks on app load.
//
// WHAT is notified is decided by `newMailNotification` below: a PURE function
// (no OS, no environment) so the whole decision table is unit-testable.
import {
  isPermissionGranted as tauriIsPermissionGranted,
  requestPermission as tauriRequestPermission,
  sendNotification as tauriSendNotification
} from '@tauri-apps/plugin-notification';
import { inDesktop } from '$lib/keychain';

/** The three permission states both backends share. */
export type NotifyPermission = 'granted' | 'denied' | 'default';

/**
 * Whether a `mail_sync` push should raise a notification, and the text it
 * would carry. PURE — every input is a plain value, so the decision table
 * (opt-in off, nothing new, permission not granted, singular vs. batched
 * text) is testable without an OS or a browser.
 *
 * `newUnread` is the sync pass's count of newly landed INBOX occurrences
 * without `S` (`Valea.Mail.SyncPass`). Anything that isn't a positive finite
 * number — `0`, `undefined` from a backend predating the field, a garbled
 * payload — is "nothing to say".
 */
export type NotifyDecision = { show: false } | { show: true; title: string; body: string };

export function newMailNotification(input: {
  /** The account SLUG — both the notification's title and its click target. */
  account: string;
  newUnread: number;
  /** The account's `notifications:` opt-in (`config/mail.yaml`, default off). */
  enabled: boolean;
  permission: NotifyPermission;
}): NotifyDecision {
  if (!input.enabled) return { show: false };
  if (input.permission !== 'granted') return { show: false };
  if (!Number.isFinite(input.newUnread) || input.newUnread < 1) return { show: false };

  // ONE notification per pass, batched — never one per message. A pass that
  // landed twelve messages is a single "12 new messages", not twelve pings.
  const body = input.newUnread === 1 ? '1 new message' : `${input.newUnread} new messages`;
  return { show: true, title: input.account, body };
}

/** Where a notification click lands: the account's mailbox. */
export function mailAccountHref(account: string): string {
  return `/mail?account=${encodeURIComponent(account)}`;
}

/**
 * The current permission, without ever asking for it.
 *
 * The desktop plugin answers a plain boolean, so a not-yet-granted state
 * can't be told apart from a refused one there — it reports `'default'`, and
 * `requestNotifyPermission` below is what resolves the ambiguity (its own
 * answer distinguishes the two). Nothing in this module treats `'default'`
 * and `'denied'` differently anyway: neither shows a notification.
 */
export async function notifyPermission(): Promise<NotifyPermission> {
  if (inDesktop()) {
    try {
      return (await tauriIsPermissionGranted()) ? 'granted' : 'default';
    } catch {
      return 'denied';
    }
  }

  if (typeof Notification === 'undefined') return 'denied';
  return normalizePermission(Notification.permission);
}

/**
 * Asks the OS for notification permission — the LAZY request, called from the
 * settings toggle the first time a user turns notifications on, never on app
 * load. Already-granted is answered without a second prompt.
 *
 * Resolves the resulting state; `'denied'` covers both a user refusal and any
 * failure (no bridge, missing capability, no `Notification` in this window),
 * because they are the same thing to the caller: this account will not get
 * notifications, so the toggle must not claim it will.
 */
export async function requestNotifyPermission(): Promise<NotifyPermission> {
  if (inDesktop()) {
    try {
      if (await tauriIsPermissionGranted()) return 'granted';
      return normalizePermission(await tauriRequestPermission());
    } catch {
      return 'denied';
    }
  }

  if (typeof Notification === 'undefined') return 'denied';
  if (Notification.permission === 'granted') return 'granted';

  try {
    return normalizePermission(await Notification.requestPermission());
  } catch {
    return 'denied';
  }
}

/**
 * The `mail_sync` reaction: reads the live permission, asks
 * `newMailNotification` whether to speak, and posts it. Resolves whether a
 * notification was actually shown (the store ignores it; tests read it).
 *
 * Never requests permission — a background sync pass is not a moment to
 * prompt. An account whose opt-in is on but whose permission was never
 * granted stays silent until the user flips the toggle again.
 */
export async function notifyNewMail(
  account: string,
  newUnread: number,
  enabled: boolean
): Promise<boolean> {
  // Cheapest gate first: an account that never opted in costs no IPC at all.
  if (!enabled) return false;

  const permission = await notifyPermission();
  const decision = newMailNotification({ account, newUnread, enabled, permission });
  if (!decision.show) return false;

  return show(account, decision.title, decision.body);
}

function show(account: string, title: string, body: string): boolean {
  if (inDesktop()) {
    try {
      // Desktop notifications carry no click callback through this plugin —
      // the OS banner is informational there. The browser path below wires
      // the click; both land on the same href when they can.
      tauriSendNotification({ title, body });
      return true;
    } catch {
      return false;
    }
  }

  if (typeof Notification === 'undefined') return false;

  try {
    // `tag` collapses a re-notification for the SAME account onto the
    // previous banner instead of stacking one per poll cycle.
    const notification = new Notification(title, { body, tag: `valea-mail-${account}` });
    notification.onclick = () => focusMailAccount(account);
    return true;
  } catch {
    return false;
  }
}

/**
 * Brings the window forward and navigates to the account's mailbox. A full
 * document load rather than a SvelteKit `goto`: this is a plain module with
 * no router runtime, and the click arrives while the app is backgrounded —
 * the URL is the whole instruction, and `/mail`'s `?account=` param is the
 * source of truth for which mailbox is open.
 */
function focusMailAccount(account: string): void {
  if (typeof window === 'undefined') return;

  try {
    window.focus();
    window.location.assign(mailAccountHref(account));
  } catch {
    // Nothing a caller can do about a blocked focus/navigate; the
    // notification itself already did its job.
  }
}

function normalizePermission(raw: string): NotifyPermission {
  if (raw === 'granted') return 'granted';
  if (raw === 'denied') return 'denied';
  return 'default';
}
