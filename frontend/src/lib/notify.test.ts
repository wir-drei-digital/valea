import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// The third-party Tauri plugin is mocked (not the module under test) so the
// desktop path drives `notify.ts`'s real call sites without a webview bridge
// — same setup as updater.test.ts / keychain.test.ts.
vi.mock('@tauri-apps/plugin-notification', () => ({
  isPermissionGranted: vi.fn(async () => false),
  requestPermission: vi.fn(async () => 'default'),
  sendNotification: vi.fn()
}));

import {
  isPermissionGranted,
  requestPermission,
  sendNotification
} from '@tauri-apps/plugin-notification';
import {
  newMailNotification,
  mailAccountHref,
  notifyPermission,
  requestNotifyPermission,
  notifyNewMail
} from './notify';

/**
 * A stand-in for the browser `Notification` constructor: records what it was
 * constructed with and exposes the instance so a click can be fired at it.
 * `permission`/`requestPermission` are statics on the real one.
 */
function stubNotification(options: {
  permission: NotificationPermission;
  requested?: NotificationPermission;
  throws?: boolean;
}) {
  const built: { title: string; body?: string; tag?: string; instance: any }[] = [];

  const ctor: any = function (this: any, title: string, init?: NotificationOptions) {
    if (options.throws) throw new Error('notifications unavailable');
    this.onclick = null;
    built.push({ title, body: init?.body, tag: init?.tag, instance: this });
  };
  ctor.permission = options.permission;
  ctor.requestPermission = vi.fn(async () => options.requested ?? options.permission);

  vi.stubGlobal('Notification', ctor);
  return { built, ctor };
}

beforeEach(() => {
  vi.mocked(isPermissionGranted).mockReset().mockResolvedValue(false);
  vi.mocked(requestPermission).mockReset().mockResolvedValue('default');
  vi.mocked(sendNotification).mockReset();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// ---------------------------------------------------------------------------
// The pure decision — no OS, no environment, the whole table.
// ---------------------------------------------------------------------------

describe('newMailNotification (pure)', () => {
  const base = { account: 'mara', newUnread: 3, enabled: true, permission: 'granted' as const };

  it('shows a batched notification when the account opted in and mail landed', () => {
    expect(newMailNotification(base)).toEqual({
      show: true,
      title: 'mara',
      body: '3 new messages'
    });
  });

  it('says "1 new message" (singular) for exactly one', () => {
    expect(newMailNotification({ ...base, newUnread: 1 })).toEqual({
      show: true,
      title: 'mara',
      body: '1 new message'
    });
  });

  it('stays silent when the account has not opted in', () => {
    expect(newMailNotification({ ...base, enabled: false })).toEqual({ show: false });
  });

  it('stays silent when the pass landed no unread inbox mail', () => {
    expect(newMailNotification({ ...base, newUnread: 0 })).toEqual({ show: false });
  });

  it('stays silent when permission was denied', () => {
    expect(newMailNotification({ ...base, permission: 'denied' })).toEqual({ show: false });
  });

  it('stays silent when permission was never granted (default)', () => {
    expect(newMailNotification({ ...base, permission: 'default' })).toEqual({ show: false });
  });

  it('stays silent on a missing or nonsense count (a backend predating the field)', () => {
    expect(newMailNotification({ ...base, newUnread: undefined as never })).toEqual({
      show: false
    });
    expect(newMailNotification({ ...base, newUnread: NaN })).toEqual({ show: false });
    expect(newMailNotification({ ...base, newUnread: -2 })).toEqual({ show: false });
  });

  it('carries the account slug as the title, so a two-account workspace can tell them apart', () => {
    const a = newMailNotification({ ...base, account: 'work' });
    const b = newMailNotification({ ...base, account: 'personal' });
    expect(a).toMatchObject({ title: 'work' });
    expect(b).toMatchObject({ title: 'personal' });
  });
});

describe('mailAccountHref', () => {
  it('points at the account s mailbox', () => {
    expect(mailAccountHref('mara')).toBe('/mail?account=mara');
  });

  it('encodes the slug', () => {
    expect(mailAccountHref('a b&c')).toBe('/mail?account=a%20b%26c');
  });
});

// ---------------------------------------------------------------------------
// Browser backend (no Tauri bridge) — the `bun run dev` / vitest environment.
// ---------------------------------------------------------------------------

describe('browser backend', () => {
  it('reports denied when the window has no Notification API at all', async () => {
    vi.stubGlobal('Notification', undefined);
    await expect(notifyPermission()).resolves.toBe('denied');
    await expect(requestNotifyPermission()).resolves.toBe('denied');
    await expect(notifyNewMail('mara', 3, true)).resolves.toBe(false);
  });

  it('reads the live permission without asking for it', async () => {
    const { ctor } = stubNotification({ permission: 'default' });
    await expect(notifyPermission()).resolves.toBe('default');
    expect(ctor.requestPermission).not.toHaveBeenCalled();
  });

  it('requestNotifyPermission asks, and reports what the user answered', async () => {
    const { ctor } = stubNotification({ permission: 'default', requested: 'granted' });
    await expect(requestNotifyPermission()).resolves.toBe('granted');
    expect(ctor.requestPermission).toHaveBeenCalledTimes(1);
  });

  it('requestNotifyPermission reports a refusal as denied', async () => {
    stubNotification({ permission: 'default', requested: 'denied' });
    await expect(requestNotifyPermission()).resolves.toBe('denied');
  });

  it('requestNotifyPermission does not re-prompt when already granted', async () => {
    const { ctor } = stubNotification({ permission: 'granted' });
    await expect(requestNotifyPermission()).resolves.toBe('granted');
    expect(ctor.requestPermission).not.toHaveBeenCalled();
  });

  it('shows one tagged notification for a granted, opted-in account', async () => {
    const { built } = stubNotification({ permission: 'granted' });

    await expect(notifyNewMail('mara', 4, true)).resolves.toBe(true);
    expect(built).toHaveLength(1);
    expect(built[0].title).toBe('mara');
    expect(built[0].body).toBe('4 new messages');
    expect(built[0].tag).toBe('valea-mail-mara');
  });

  it('never asks for permission from the sync path — an ungranted account stays silent', async () => {
    const { built, ctor } = stubNotification({ permission: 'default' });

    await expect(notifyNewMail('mara', 4, true)).resolves.toBe(false);
    expect(built).toHaveLength(0);
    expect(ctor.requestPermission).not.toHaveBeenCalled();
  });

  it('does not even read the permission for an account that never opted in', async () => {
    const { built } = stubNotification({ permission: 'granted' });

    await expect(notifyNewMail('mara', 4, false)).resolves.toBe(false);
    expect(built).toHaveLength(0);
  });

  it('resolves false — never throws — when the constructor itself fails', async () => {
    stubNotification({ permission: 'granted', throws: true });
    await expect(notifyNewMail('mara', 1, true)).resolves.toBe(false);
  });

  it('a click focuses the account s mailbox', async () => {
    const { built } = stubNotification({ permission: 'granted' });
    const assign = vi.fn();
    const focus = vi.fn();
    vi.stubGlobal('window', { focus, location: { assign } });

    await notifyNewMail('mara', 2, true);
    built[0].instance.onclick();

    expect(focus).toHaveBeenCalled();
    expect(assign).toHaveBeenCalledWith('/mail?account=mara');
  });
});

// ---------------------------------------------------------------------------
// Desktop backend (Tauri bridge present) — the plugin, behind the same
// contract.
// ---------------------------------------------------------------------------

describe('desktop backend', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { __TAURI_INTERNALS__: {} });
  });

  it('maps the plugin s boolean onto the shared permission states', async () => {
    vi.mocked(isPermissionGranted).mockResolvedValue(true);
    await expect(notifyPermission()).resolves.toBe('granted');

    vi.mocked(isPermissionGranted).mockResolvedValue(false);
    await expect(notifyPermission()).resolves.toBe('default');
  });

  it('reports denied — never throws — when the bridge or capability is missing', async () => {
    vi.mocked(isPermissionGranted).mockRejectedValue(new Error('not allowed'));
    await expect(notifyPermission()).resolves.toBe('denied');
    await expect(requestNotifyPermission()).resolves.toBe('denied');
    await expect(notifyNewMail('mara', 3, true)).resolves.toBe(false);
    expect(sendNotification).not.toHaveBeenCalled();
  });

  it('requestNotifyPermission asks the plugin only when not already granted', async () => {
    vi.mocked(isPermissionGranted).mockResolvedValue(true);
    await expect(requestNotifyPermission()).resolves.toBe('granted');
    expect(requestPermission).not.toHaveBeenCalled();

    vi.mocked(isPermissionGranted).mockResolvedValue(false);
    vi.mocked(requestPermission).mockResolvedValue('granted');
    await expect(requestNotifyPermission()).resolves.toBe('granted');
    expect(requestPermission).toHaveBeenCalledTimes(1);
  });

  it('sends one batched notification through the plugin', async () => {
    vi.mocked(isPermissionGranted).mockResolvedValue(true);

    await expect(notifyNewMail('work', 12, true)).resolves.toBe(true);
    expect(sendNotification).toHaveBeenCalledTimes(1);
    expect(sendNotification).toHaveBeenCalledWith({ title: 'work', body: '12 new messages' });
  });

  it('sends nothing for an account that has not opted in', async () => {
    vi.mocked(isPermissionGranted).mockResolvedValue(true);

    await expect(notifyNewMail('work', 12, false)).resolves.toBe(false);
    expect(sendNotification).not.toHaveBeenCalled();
  });

  it('sends nothing for a pass that landed no unread inbox mail', async () => {
    vi.mocked(isPermissionGranted).mockResolvedValue(true);

    await expect(notifyNewMail('work', 0, true)).resolves.toBe(false);
    expect(sendNotification).not.toHaveBeenCalled();
  });
});
