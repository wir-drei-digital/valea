/**
 * The mail read surface's selection load — account switch first, then the
 * message, in ONE ordered effect with the later of two overlapping loads
 * winning.
 *
 * ONE copy, deliberately. This was written for `/mail`, then copied
 * near-verbatim into `MailPane` when the pane arrived, and the comments below
 * record a race that was already caught live once on an earlier revision. Two
 * copies of subtle race handling drift, and the drift is invisible until
 * someone clicks quickly down a message list. `/mail` and `MailPane` differ in
 * where the selection COMES FROM — a URL on one, a pane descriptor on the
 * other — so that is the only thing this takes as a parameter.
 *
 * Why each piece is the way it is:
 *
 * - `MailStore.select` writes the shared `mailStore.selected` singleton with no
 *   per-call id tag, so two in-flight loads (rapid clicking) can resolve out of
 *   order. `cancelled` drops the stale one instead of flashing the wrong body.
 * - `mailStore.selected !== before` is the only available signal for "the fetch
 *   actually landed" versus "it failed and left the old value alone": `select()`
 *   returns `Promise<void>` and early-exits on failure, so reference identity is
 *   the only distinction available without changing the store's contract.
 * - Both `mailStore.selected` reads are UNTRACKED, and that is load-bearing
 *   rather than decorative: this effect's own `select()` is what LATER mutates
 *   it, so a tracked read would re-trigger the effect — an endless
 *   `get_mail_message` loop keyed on nothing the user did (caught live on an
 *   earlier revision).
 * - `selectedAccount` and the ARRIVAL of accounts ARE tracked. A deep link that
 *   lands before `refreshStatus` resolves has no account yet, and "no account
 *   YET" must not be treated as "no account" — it waits, and the effect re-runs
 *   when the accounts land.
 * - `targetAccount`'s membership SCAN is untracked. It reads every row, and
 *   `handleMailStatus` replaces a row object on every `mail_status` push —
 *   several per poll cycle, none of which change which accounts exist. Tracking
 *   it re-ran the whole effect (clearing the detail, re-fetching the open
 *   message) roughly twice a poll: a visible read-pane flicker and redundant
 *   RPCs on a screen nobody was touching. `accounts.length` stays the
 *   arrived-signal; the scan itself is not.
 * - The account switch runs BEFORE the `!id` bail-out, because switching
 *   accounts with no message open is exactly that case. On `/mail` this effect
 *   is also the only thing that switches accounts (`?account=` is the source of
 *   truth — `AccountSwitcher` navigates rather than writing the store, or its
 *   write would race the URL and be reverted here).
 *
 * `selectAccount` and `select` are `MailStore`'s existing methods; there is no
 * `openMessage`.
 */
import { untrack } from 'svelte';
import { targetAccount } from './mail-shapes';
import { mailStore, type MailMessageDetail } from '$lib/stores/mail.svelte';

export type MailSelection = {
  /** The id the loaded detail belongs to — compare against your own selection before rendering. */
  readonly activeId: string | null;
  readonly detail: MailMessageDetail | null;
  /** The load finished and produced nothing; distinct from "still loading". */
  readonly failed: boolean;
};

/**
 * Starts the effect and hands back its result. Call during component init —
 * it creates an `$effect`, so it inherits the caller's lifecycle and is torn
 * down with it.
 *
 * `selection` is read reactively on every run: return the msg id and the
 * account the host wants shown (`?message=`/`?account=` for the route, the
 * descriptor for the pane).
 */
export function watchMailSelection(
  selection: () => { msgId: string | null; account: string | null }
): MailSelection {
  let activeId = $state<string | null>(null);
  let detail = $state<MailMessageDetail | null>(null);
  let failed = $state(false);

  $effect(() => {
    const { msgId: id, account: wanted } = selection();
    const storeAccount = mailStore.selectedAccount;
    const accountsReady = mailStore.accounts.length > 0;
    const target = untrack(() => targetAccount(wanted, storeAccount, mailStore.accounts));
    activeId = null;
    detail = null;
    failed = false;

    let cancelled = false;
    void (async () => {
      if (target && target !== storeAccount) {
        await mailStore.selectAccount(target);
        if (cancelled) return;
      }
      if (!id) return;
      if (!target) {
        if (accountsReady) failed = true; // accounts loaded, none selectable
        return; // otherwise wait — the effect re-runs when accounts arrive
      }
      const before = untrack(() => mailStore.selected);
      await mailStore.select(id);
      if (cancelled) return;
      const selected = untrack(() => mailStore.selected);
      if (selected !== before) {
        activeId = id;
        detail = selected;
      } else {
        failed = true;
      }
    })();

    return () => {
      cancelled = true;
    };
  });

  return {
    get activeId() {
      return activeId;
    },
    get detail() {
      return detail;
    },
    get failed() {
      return failed;
    }
  };
}
