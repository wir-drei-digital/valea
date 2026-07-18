import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  CalendarStore,
  normalizeCalendarSourceStatus,
  normalizeOccurrence,
  resupplyCalendarUrls
} from './calendar.svelte';
import { inDesktop, keychainGet, keychainSet } from '../keychain';
import { workspaceStore } from './workspace.svelte';
import type { CalendarStatusPush } from '../socket';

vi.mock('../keychain', () => ({
  inDesktop: vi.fn(() => false),
  keychainGet: vi.fn(async () => null),
  keychainSet: vi.fn(async () => true)
}));

beforeEach(() => {
  vi.mocked(inDesktop).mockReset().mockReturnValue(false);
  vi.mocked(keychainGet).mockReset().mockResolvedValue(null);
  vi.mocked(keychainSet).mockReset().mockResolvedValue(true);
  workspaceStore.id = 'ws-1';
  workspaceStore.generation = 7;
});

type Call = { fn: string; args: unknown[] };

/** Records every call in order and returns canned ApiResults — the `Pick<Api>` fake convention. */
function fakeApi(overrides: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const ok = (data: unknown) => async (...args: unknown[]) => ({ ok: true as const, data });
  const record =
    (fn: string, impl: (...args: unknown[]) => Promise<unknown>) =>
    async (...args: unknown[]) => {
      calls.push({ fn, args });
      return impl(...args);
    };

  const base: Record<string, (...args: unknown[]) => Promise<unknown>> = {
    calendarStatus: ok({ sources: [], feedEnabled: false, valeaEventCount: 0, configInvalid: null }),
    setupCalendarSource: ok({ saved: true }),
    setCalendarSourceUrl: ok({ accepted: true }),
    removeCalendarSource: ok({ removed: true }),
    purgeCalendarSourceFiles: ok({ purged: true }),
    calendarSyncNow: ok({ started: true }),
    calendarDoctor: ok({ ok: true, checks: [] }),
    listCalendarEvents: ok({ events: [] }),
    createValeaEvent: ok({ created: true, path: 'sources/calendar/valea/events/x.md' }),
    updateValeaEvent: ok({ updated: true }),
    deleteValeaEvent: ok({ deleted: true }),
    enableCalendarFeed: ok({ token: 'plain-token-1' }),
    rotateCalendarFeedToken: ok({ token: 'plain-token-2' }),
    ...(overrides as Record<string, (...args: unknown[]) => Promise<unknown>>)
  };

  const wrapped = Object.fromEntries(Object.entries(base).map(([fn, impl]) => [fn, record(fn, impl)]));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return { api: wrapped as any, calls };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function statusEntry(partial: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source: 'work',
    state: 'idle',
    last_sync_at: '2026-07-18T08:00:00Z',
    last_error: null,
    event_count: 12,
    notices: [],
    url_present: true,
    unsupported_series: 0,
    ...partial
  };
}

describe('normalizeCalendarSourceStatus', () => {
  it('camelCases a valid engine entry and defaults valid to true', () => {
    const status = normalizeCalendarSourceStatus(statusEntry({ unsupported_series: 2 }));
    expect(status).toMatchObject({
      source: 'work',
      valid: true,
      state: 'idle',
      eventCount: 12,
      urlPresent: true,
      unsupportedSeries: 2
    });
  });

  it('degrades an invalid-config entry to empty engine defaults', () => {
    const status = normalizeCalendarSourceStatus({
      source: 'broken',
      valid: false,
      state: 'invalid_config',
      reason: 'window.past_days must be an integer'
    });
    expect(status).toMatchObject({
      source: 'broken',
      valid: false,
      reason: 'window.past_days must be an integer',
      state: 'invalid_config',
      eventCount: 0,
      urlPresent: false,
      unsupportedSeries: 0
    });
  });
});

describe('normalizeOccurrence', () => {
  it('passes a tagged wire row through and rejects a shapeless one', () => {
    expect(
      normalizeOccurrence({
        source: 'valea',
        all_day: true,
        start: '2026-07-21',
        end: '2026-07-22',
        summary: 'Offsite',
        location: null,
        status: 'confirmed',
        description: 'Agenda',
        view_path: null,
        path: 'sources/calendar/valea/events/offsite.md'
      })
    ).toMatchObject({ source: 'valea', all_day: true, path: 'sources/calendar/valea/events/offsite.md' });
    expect(normalizeOccurrence({ summary: 'no times' })).toBeNull();
  });
});

describe('CalendarStore.refreshStatus', () => {
  it('normalizes sources and the typed top-level fields (invalid entries + config_invalid surface)', async () => {
    const { api } = fakeApi({
      calendarStatus: async () => ({
        ok: true,
        data: {
          sources: [statusEntry(), { source: 'broken', valid: false, state: 'invalid_config', reason: 'bad yaml' }],
          feedEnabled: true,
          valeaEventCount: 3,
          configInvalid: null
        }
      })
    });
    const store = new CalendarStore(api);
    await store.refreshStatus();

    expect(store.sources.map((s) => [s.source, s.valid])).toEqual([
      ['work', true],
      ['broken', false]
    ]);
    expect(store.sources[1].reason).toBe('bad yaml');
    expect(store.feedEnabled).toBe(true);
    expect(store.valeaEventCount).toBe(3);
    expect(store.configInvalid).toBeNull();
  });

  it('surfaces a whole-file invalid config while staying usable', async () => {
    const { api } = fakeApi({
      calendarStatus: async () => ({
        ok: true,
        data: { sources: [], feedEnabled: false, valeaEventCount: 0, configInvalid: 'not a v1 mapping' }
      })
    });
    const store = new CalendarStore(api);
    await store.refreshStatus();
    expect(store.configInvalid).toBe('not a v1 mapping');
    expect(store.sources).toEqual([]);
  });
});

describe('CalendarStore events range', () => {
  it('loads rows for a range and refreshes the SAME range on demand', async () => {
    const { api, calls } = fakeApi({
      listCalendarEvents: async (...args: unknown[]) => ({
        ok: true,
        data: {
          events: [
            {
              source: 'work',
              all_day: false,
              start: '2026-07-21T07:30:00Z',
              end: '2026-07-21T08:00:00Z',
              summary: 'Standup',
              location: null,
              status: 'confirmed',
              description: null,
              view_path: 'sources/calendar/work/views/events/ev-1.md',
              path: null
            },
            { junk: true }
          ]
        }
      })
    });
    const store = new CalendarStore(api);
    await store.loadEvents('2026-07-20', '2026-07-27', 'Europe/Zurich');

    expect(store.events).toHaveLength(1);
    expect(store.events[0].summary).toBe('Standup');
    const listCalls = calls.filter((c) => c.fn === 'listCalendarEvents');
    expect(listCalls[0].args).toEqual(['2026-07-20', '2026-07-27', 'Europe/Zurich']);
  });
});

describe('CalendarStore.addSource — the pinned setup → set-url → keychain sequence', () => {
  it('runs the three steps in exactly that order and stores the URL only on acceptance', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const { api, calls } = fakeApi();
    const store = new CalendarStore(api);

    const result = await store.addSource('work', 'Work (Google)', 'https://cal.example/secret.ics', 7);

    expect(result).toEqual({ ok: true, urlStored: true });
    const order = calls.map((c) => c.fn).filter((fn) => fn === 'setupCalendarSource' || fn === 'setCalendarSourceUrl');
    expect(order).toEqual(['setupCalendarSource', 'setCalendarSourceUrl']);
    expect(vi.mocked(keychainSet)).toHaveBeenCalledWith('ws-1', 'work:ics', 'https://cal.example/secret.ics');
    // keychainSet strictly after the RPC acceptance:
    expect(calls.findIndex((c) => c.fn === 'setCalendarSourceUrl')).toBeGreaterThan(
      calls.findIndex((c) => c.fn === 'setupCalendarSource')
    );
  });

  it('NEVER touches the keychain when the URL is rejected', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const { api } = fakeApi({
      setCalendarSourceUrl: async () => ({ ok: false, error: 'not_https' })
    });
    const store = new CalendarStore(api);

    const result = await store.addSource('work', 'Work', 'http://cal.example/insecure.ics', 7);

    expect(result).toEqual({ ok: false, error: 'not_https', stage: 'url' });
    expect(vi.mocked(keychainSet)).not.toHaveBeenCalled();
  });

  it('treats a keychain-write failure as a retryable warning, not a setup failure', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainSet).mockResolvedValue(false);
    const { api } = fakeApi();
    const store = new CalendarStore(api);

    const result = await store.addSource('work', 'Work', 'https://cal.example/secret.ics', 7);

    expect(result).toEqual({ ok: true, urlStored: false });
    expect(store.urlNotStored).toEqual(['work']);

    vi.mocked(keychainSet).mockResolvedValue(true);
    await expect(store.retryStoreUrl('work', 'https://cal.example/secret.ics')).resolves.toBe(true);
    expect(store.urlNotStored).toEqual([]);
  });
});

describe('CalendarStore pushes', () => {
  it('upserts a calendar_status push by slug (unsupported_series rides along for the "N series unsupported" line)', async () => {
    const { api } = fakeApi();
    const store = new CalendarStore(api);

    store.handleCalendarStatus(statusEntry({ unsupported_series: 2 }) as unknown as CalendarStatusPush);
    expect(store.sources.map((s) => s.source)).toEqual(['work']);
    expect(store.sources[0].unsupportedSeries).toBe(2);

    store.handleCalendarStatus(statusEntry({ state: 'syncing' }) as unknown as CalendarStatusPush);
    expect(store.sources).toHaveLength(1);
    expect(store.sources[0].state).toBe('syncing');
  });

  it('calendar_synced updates the count and refetches the visible range', async () => {
    const { api, calls } = fakeApi();
    const store = new CalendarStore(api);
    await store.loadEvents('2026-07-20', '2026-07-27', 'Europe/Zurich');
    store.handleCalendarStatus(statusEntry() as unknown as CalendarStatusPush);
    calls.length = 0;

    store.handleCalendarSynced({ source: 'work', event_count: 13 });
    await flush();

    expect(store.sources[0].eventCount).toBe(13);
    expect(calls.some((c) => c.fn === 'listCalendarEvents')).toBe(true);
  });

  it('calendar_local_changed refetches events AND status (valea count changed)', async () => {
    const { api, calls } = fakeApi();
    const store = new CalendarStore(api);
    await store.loadEvents('2026-07-20', '2026-07-27', 'Europe/Zurich');
    calls.length = 0;

    store.handleCalendarLocalChanged();
    await flush();

    expect(calls.some((c) => c.fn === 'listCalendarEvents')).toBe(true);
    expect(calls.some((c) => c.fn === 'calendarStatus')).toBe(true);
  });
});

describe('CalendarStore feed token', () => {
  it('enable is gated when already enabled (backend enable would silently rotate)', async () => {
    const { api, calls } = fakeApi();
    const store = new CalendarStore(api);
    store.feedEnabled = true;

    await expect(store.enableFeed(7)).resolves.toBe('already_enabled');
    expect(calls.some((c) => c.fn === 'enableCalendarFeed')).toBe(false);
  });

  it('enable then rotate each hold the plain token transiently', async () => {
    const { api } = fakeApi();
    const store = new CalendarStore(api);

    await expect(store.enableFeed(7)).resolves.toBeNull();
    expect(store.feedToken).toBe('plain-token-1');
    expect(store.feedEnabled).toBe(true);

    await expect(store.rotateFeed(7)).resolves.toBeNull();
    expect(store.feedToken).toBe('plain-token-2');
  });
});

describe('resupplyCalendarUrls', () => {
  it('does nothing in the browser', async () => {
    const { api } = fakeApi();
    const sources = [normalizeCalendarSourceStatus(statusEntry({ url_present: false }))];
    await expect(resupplyCalendarUrls(sources, api)).resolves.toBe(0);
    expect(vi.mocked(keychainGet)).not.toHaveBeenCalled();
  });

  it('re-supplies only urlPresent:false sources from the <slug>:ics keychain entry', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockImplementation(async (_ws, key) =>
      key === 'work:ics' ? 'https://cal.example/secret.ics' : null
    );
    const { api, calls } = fakeApi();

    const sources = [
      normalizeCalendarSourceStatus(statusEntry({ url_present: false })),
      normalizeCalendarSourceStatus(statusEntry({ source: 'home', url_present: true })),
      normalizeCalendarSourceStatus(statusEntry({ source: 'missing', url_present: false }))
    ];
    await expect(resupplyCalendarUrls(sources, api)).resolves.toBe(1);

    expect(vi.mocked(keychainGet)).toHaveBeenCalledWith('ws-1', 'work:ics');
    expect(vi.mocked(keychainGet)).toHaveBeenCalledWith('ws-1', 'missing:ics');
    const setCalls = calls.filter((c) => c.fn === 'setCalendarSourceUrl');
    expect(setCalls).toHaveLength(1);
    expect(setCalls[0].args).toEqual(['work', 'https://cal.example/secret.ics', 7]);
  });
});
