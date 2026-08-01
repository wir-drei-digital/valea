/**
 * What the ＋ Pane menu offers. Every item must name a CONCRETE subject — no
 * descriptor kind accepts "empty" — so this resolves a mount and an account
 * up front rather than opening a picker.
 *
 * Availability is only ever asserted from LOADED data: an unknown mail status
 * leaves the item enabled and lets the Mail pane show its own no-account empty
 * state, which is both truthful and recoverable.
 *
 * `resolveIcmSelection`, deliberately NOT `resolveActiveMountKey`: the latter
 * bottoms out at `?icm=` and so returns null on Today or Tasks, which would
 * disable Files and Chat beside a perfectly healthy workspace. Callers filter
 * `m.enabled && !m.degraded` before passing `enabledMountKeys`, so a degraded
 * or deactivated mount is never offered as a subject.
 *
 * `mailAccounts` is ordered by the caller, preferred account first — that is
 * `mailStore.selectedAccount` when there is one, so "the first account" means
 * "the mailbox the user is reading".
 */
import { resolveIcmSelection } from './icm-route';
import type { PaneDescriptor } from '$lib/panes/pane-route';

export type MenuItem = {
  kind: 'files' | 'chat' | 'mail';
  label: string;
  descriptor: PaneDescriptor | null;
  disabledReason: string | null;
};

/**
 * Whether the bar may offer this item — the ONE predicate the UI gates on,
 * exported so a test asserts the same thing the button does.
 *
 * It is `disabledReason`, not `descriptor !== null`, and the difference is the
 * whole three-valued mail cell. Gating on the descriptor greyed out the
 * "status has not arrived yet" case, which carries no reason and therefore
 * greyed SILENTLY — worse than either intended outcome, since a disabled
 * control with nothing to say teaches nothing. Unknown stays live; only a
 * loaded answer disables.
 */
export function menuItemEnabled(item: MenuItem): boolean {
  return item.disabledReason === null;
}

export function menuItems(input: {
  icmParam: string | null;
  enabledMountKeys: string[];
  mailAccounts: string[];
  mailStatusLoaded: boolean;
  openKinds: string[];
}): MenuItem[] {
  const mount = resolveIcmSelection(input.icmParam, input.enabledMountKeys);
  const account = input.mailAccounts[0] ?? null;
  const mailAbsent = input.mailStatusLoaded && input.mailAccounts.length === 0;

  const items: MenuItem[] = [
    {
      kind: 'files',
      label: 'Files',
      descriptor: mount ? { kind: 'files', mountKey: mount, paths: [], active: 0, compare: null } : null,
      disabledReason: mount ? null : 'No ICM is mounted yet'
    },
    {
      kind: 'chat',
      label: 'Chat',
      descriptor: mount ? { kind: 'chat-new', mountKey: mount } : null,
      disabledReason: mount ? null : 'No ICM is mounted yet'
    },
    {
      kind: 'mail',
      label: 'Mail',
      descriptor: mailAbsent || !account ? null : { kind: 'mail', account, msgId: null },
      disabledReason: mailAbsent ? 'No mail account yet' : null
    }
  ];

  // A kind already on screen is shown checked and inert rather than hidden.
  return items.map((i) =>
    input.openKinds.includes(i.kind === 'chat' ? 'chat-new' : i.kind) ||
    input.openKinds.includes(i.kind)
      ? { ...i, descriptor: null, disabledReason: 'Already open' }
      : i
  );
}
