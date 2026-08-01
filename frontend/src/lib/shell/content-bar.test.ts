import { describe, expect, it } from 'vitest';
import { menuItems } from './content-bar';

const base = {
  // Annotated for the same reason the brief annotates `openKinds`: `Partial<typeof base>`
  // would otherwise narrow the override to `null`, and the `?icm=` case could not be written.
  icmParam: null as string | null,
  enabledMountKeys: ['life', 'valea'],
  mailAccounts: ['mara@example.com'],
  mailStatusLoaded: true,
  openKinds: [] as string[]
};

function item(kind: string, over: Partial<typeof base> = {}) {
  return menuItems({ ...base, ...over }).find((i) => i.kind === kind)!;
}

describe('menuItems', () => {
  it('finds a mount with no ?icm= at all — the Today/Tasks case', () => {
    expect(item('files').descriptor).toEqual({ kind: 'files', mountKey: 'life', paths: [] });
    expect(item('chat').descriptor).toEqual({ kind: 'chat-new', mountKey: 'life' });
  });

  it('honours an explicit ?icm=', () => {
    expect(item('files', { icmParam: 'valea' }).descriptor).toEqual({
      kind: 'files',
      mountKey: 'valea',
      paths: []
    });
  });

  it('disables Files and Chat when no mount is enabled', () => {
    const none = { enabledMountKeys: [] };
    expect(item('files', none).descriptor).toBeNull();
    expect(item('files', none).disabledReason).toBe('No ICM is mounted yet');
    expect(item('chat', none).descriptor).toBeNull();
  });

  it('opens Mail on the first configured account', () => {
    expect(item('mail').descriptor).toEqual({
      kind: 'mail',
      account: 'mara@example.com',
      msgId: null
    });
  });

  it('stays enabled while mail status is unknown', () => {
    const unknown = { mailAccounts: [], mailStatusLoaded: false };
    expect(item('mail', unknown).disabledReason).toBeNull();
  });

  it('disables Mail only once a loaded status shows no account', () => {
    const none = { mailAccounts: [], mailStatusLoaded: true };
    expect(item('mail', none).descriptor).toBeNull();
    expect(item('mail', none).disabledReason).toBe('No mail account yet');
  });

  it('marks a kind that is already open as inert', () => {
    expect(item('chat', { openKinds: ['chat'] }).disabledReason).toBe('Already open');
  });

  // --- the cases the seven above leave open ---------------------------------

  it('offers exactly Files, Chat and Mail, in that order', () => {
    expect(menuItems(base).map((i) => i.kind)).toEqual(['files', 'chat', 'mail']);
    expect(menuItems(base).map((i) => i.label)).toEqual(['Files', 'Chat', 'Mail']);
  });

  it('counts a chat-new pane as Chat being open', () => {
    // `/knowledge`'s session picker opens `chat:new:<mount>`; the menu must
    // not offer a SECOND chat surface just because the open one has not
    // started its session yet.
    expect(item('chat', { openKinds: ['chat-new'] }).disabledReason).toBe('Already open');
  });

  it('withholds the descriptor of an already-open kind', () => {
    // Belt and braces for the bar: an inert row must not carry something
    // clickable, or a keyboard activation would open a duplicate surface.
    expect(item('files', { openKinds: ['files'] }).descriptor).toBeNull();
    expect(item('mail', { openKinds: ['mail'] }).descriptor).toBeNull();
  });

  it('reports "Already open" ahead of an unavailable reason', () => {
    // The user can see the surface on screen; telling them there is no ICM
    // mounted while its tree is visible beside the menu would be a lie.
    const both = { enabledMountKeys: [], openKinds: ['files'] };
    expect(item('files', both).disabledReason).toBe('Already open');
  });

  it('leaves Mail enabled when status is unknown AND an account is already cached', () => {
    // `mailStore.accounts` can be populated by a push before `refreshStatus`
    // resolves; an account in hand is an account, loaded flag or not.
    const early = { mailAccounts: ['mara@example.com'], mailStatusLoaded: false };
    expect(item('mail', early).descriptor).toEqual({
      kind: 'mail',
      account: 'mara@example.com',
      msgId: null
    });
    expect(item('mail', early).disabledReason).toBeNull();
  });

  it('takes the FIRST account, which is the caller’s preferred one', () => {
    // `ContentBar`'s caller puts `mailStore.selectedAccount` at the head of
    // the list, so "first" means "the one the user is reading".
    expect(item('mail', { mailAccounts: ['b@example.com', 'a@example.com'] }).descriptor).toEqual({
      kind: 'mail',
      account: 'b@example.com',
      msgId: null
    });
  });

  it('leaves Mail with no descriptor and no reason while status is still unknown', () => {
    // The one genuinely three-valued cell: nothing to open yet, but nothing
    // has been LEARNED yet either, so the item stays live and the Mail pane
    // shows its own empty state. Asserted together because a reason without
    // a descriptor is what "disabled" means, and this is neither.
    const unknown = { mailAccounts: [], mailStatusLoaded: false };
    expect(item('mail', unknown).descriptor).toBeNull();
    expect(item('mail', unknown).disabledReason).toBeNull();
  });
});
