import { api, type Api, type ValeaEventAttrs } from '../api/client';
import { workspaceStore } from './workspace.svelte';
import { inDesktop, keychainGet, keychainSet } from '../keychain';
import type { CalendarOccurrence } from '../components/calendar/calendar-shapes';
import type { CalendarStatusPush, CalendarSyncedPush } from '../socket';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as `MailStore`, so tests inject a fake without implementing
 * every wrapped call.
 */
type CalendarApi = Pick<
  Api,
  | 'calendarStatus'
  | 'setupCalendarSource'
  | 'setCalendarSourceUrl'
  | 'removeCalendarSource'
  | 'purgeCalendarSourceFiles'
  | 'calendarSyncNow'
  | 'calendarDoctor'
  | 'listCalendarEvents'
  | 'createValeaEvent'
  | 'updateValeaEvent'
  | 'deleteValeaEvent'
  | 'enableCalendarFeed'
  | 'rotateCalendarFeedToken'
>;

/**
 * One source's app-facing status — camelCased/typed from the raw per-source
 * entry of `calendar_status`'s `sources` list (and, identically shaped minus
 * `valid`/`reason`, the `calendar_status` channel push). An invalid-config
 * entry (`valid: false`) carries only `source`/`state: "invalid_config"`/
 * `reason`; every engine field degrades to its empty default for those.
 */
export type CalendarSourceStatus = {
  source: string;
  valid: boolean;
  /** Invalid-config explanation (`valid: false` entries only); `null` on valid sources. */
  reason: string | null;
  state: string;
  lastSyncAt: string | null;
  lastError: string | null;
  eventCount: number;
  notices: string[];
  /** Credential-style boolean — the feed URL is RAM-only backend-side; `false` triggers resupply. */
  urlPresent: boolean;
  /** Spec F's "N series unsupported" count — rendered on the source's status line when > 0. */
  unsupportedSeries: number;
};

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function strings(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : [];
}

function num(v: unknown): number {
  return typeof v === 'number' ? v : 0;
}

/** Normalizes one raw source entry (RPC `sources` item or a `calendar_status` push — identical snake_case shapes). */
export function normalizeCalendarSourceStatus(raw: Record<string, unknown>): CalendarSourceStatus {
  return {
    source: str(raw.source) ?? '',
    valid: raw.valid !== false,
    reason: str(raw.reason),
    state: str(raw.state) ?? 'inactive',
    lastSyncAt: str(raw.last_sync_at),
    lastError: str(raw.last_error),
    eventCount: num(raw.event_count),
    notices: strings(raw.notices),
    urlPresent: raw.url_present === true,
    unsupportedSeries: num(raw.unsupported_series)
  };
}

/** Narrow guard for wire rows — the grids only ever see rows that pass this. */
export function normalizeOccurrence(raw: Record<string, unknown>): CalendarOccurrence | null {
  if (typeof raw.source !== 'string' || typeof raw.start !== 'string' || typeof raw.end !== 'string') return null;
  return {
    source: raw.source,
    all_day: raw.all_day === true,
    start: raw.start,
    end: raw.end,
    summary: str(raw.summary) ?? '',
    location: str(raw.location),
    status: str(raw.status) ?? 'confirmed',
    description: str(raw.description),
    view_path: str(raw.view_path),
    path: str(raw.path)
  };
}

/** `addSource`'s outcome — `urlStored: false` is the retryable keychain-failure warning state. */
export type AddSourceResult = { ok: true; urlStored: boolean } | { ok: false; error: string; stage: 'setup' | 'url' };

/**
 * Live view of the calendar subsystem: per-source statuses, the served-feed
 * block, and the occurrence rows for the visible range. Push handlers are
 * plain public methods wired through `wireCalendarEvents` below — the single
 * `workspace:events` join convention (`wireIcmEvents`'s doc comment).
 */
export class CalendarStore {
  sources: CalendarSourceStatus[] = $state([]);
  /** Whole-file invalid `config/calendar.yaml` reason (`calendar_status`'s `configInvalid`), `null` when fine. */
  configInvalid: string | null = $state(null);
  feedEnabled = $state(false);
  valeaEventCount = $state(0);
  events: CalendarOccurrence[] = $state([]);
  /** The visible range the route last loaded — refreshed in place on pushes. */
  range: { from: string; to: string; zone: string } | null = $state(null);
  /**
   * The served-feed plain token, held ONLY transiently after enable/rotate
   * (the backend stores just its hash — shown once with a copy button).
   */
  feedToken: string | null = $state(null);
  /** Slugs whose accepted URL could not be written to the keychain — "retry saving" warning (non-fatal). */
  urlNotStored: string[] = $state([]);

  #api: CalendarApi;

  constructor(api: CalendarApi) {
    this.#api = api;
  }

  async refreshStatus(): Promise<void> {
    const result = await this.#api.calendarStatus();
    if (!result.ok) return;

    const data = result.data as {
      sources?: unknown;
      feedEnabled?: boolean;
      valeaEventCount?: number;
      configInvalid?: string | null;
    };
    const raw = Array.isArray(data.sources) ? (data.sources as Record<string, unknown>[]) : [];
    this.sources = raw.map(normalizeCalendarSourceStatus);
    this.feedEnabled = data.feedEnabled === true;
    this.valeaEventCount = data.valeaEventCount ?? 0;
    this.configInvalid = data.configInvalid ?? null;
    void resupplyCalendarUrls(this.sources, this.#api);
  }

  /** Loads the occurrence rows for `[from, to)` interpreted in `zone` and remembers the range for push refreshes. */
  async loadEvents(from: string, to: string, zone: string): Promise<void> {
    this.range = { from, to, zone };
    await this.refreshEvents();
  }

  async refreshEvents(): Promise<void> {
    const range = this.range;
    if (!range) return;

    const result = await this.#api.listCalendarEvents(range.from, range.to, range.zone);
    if (!result.ok) return;
    // A slow earlier response must not clobber a newer range's rows.
    if (this.range !== range) return;

    const data = result.data as { events?: unknown };
    const raw = Array.isArray(data.events) ? (data.events as Record<string, unknown>[]) : [];
    this.events = raw.map(normalizeOccurrence).filter((row): row is CalendarOccurrence => row !== null);
  }

  /**
   * THE add-source sequence (Spec F §UI Setup panel, pinned order):
   * 1. `setup_calendar_source` — config write + rehash; the engine starts
   *    URL-less (`urlPresent: false` is a valid state, not an error);
   * 2. `set_calendar_source_url` — the engine exists now; the backend's
   *    `Fetch.validate_url` gate admits (or rejects) the URL and claims
   *    `.source`;
   * 3. `keychainSet` ONLY on step-2 success — a rejected URL never reaches
   *    the keychain. A keychain-write failure is non-fatal and retryable:
   *    the engine keeps its RAM closure for this session, and after a
   *    restart the standard resupply prompt asks again (same-URL re-entry
   *    re-matches the `.source` identity).
   */
  async addSource(slug: string, name: string, url: string, generation: number): Promise<AddSourceResult> {
    const setup = await this.#api.setupCalendarSource(slug, name, generation);
    if (!setup.ok) return { ok: false, error: setup.error, stage: 'setup' };

    const accepted = await this.#api.setCalendarSourceUrl(slug, url, generation);
    if (!accepted.ok) {
      void this.refreshStatus();
      return { ok: false, error: accepted.error, stage: 'url' };
    }

    const stored = await this.#storeUrl(slug, url);
    void this.refreshStatus();
    return { ok: true, urlStored: stored };
  }

  /** Retries the keychain write for a source whose URL was accepted but not durably stored. */
  async retryStoreUrl(slug: string, url: string): Promise<boolean> {
    return this.#storeUrl(slug, url);
  }

  async #storeUrl(slug: string, url: string): Promise<boolean> {
    const workspaceId = workspaceStore.id;
    const stored = workspaceId ? await keychainSet(workspaceId, `${slug}:ics`, url) : false;
    if (stored) {
      this.urlNotStored = this.urlNotStored.filter((s) => s !== slug);
    } else if (!this.urlNotStored.includes(slug)) {
      this.urlNotStored = [...this.urlNotStored, slug];
    }
    return stored;
  }

  async removeSource(slug: string, generation: number): Promise<string | null> {
    const result = await this.#api.removeCalendarSource(slug, generation);
    void this.refreshStatus();
    return result.ok ? null : result.error;
  }

  /** Typed-confirm purge — `confirmation` must equal the slug (the backend enforces it too). */
  async purgeSource(slug: string, confirmation: string, generation: number): Promise<string | null> {
    const result = await this.#api.purgeCalendarSourceFiles(slug, confirmation, generation);
    void this.refreshStatus();
    void this.refreshEvents();
    return result.ok ? null : result.error;
  }

  async syncNow(slug: string, generation: number): Promise<string | null> {
    const result = await this.#api.calendarSyncNow(slug, generation);
    return result.ok ? null : result.error;
  }

  async doctor(slug: string, generation: number): Promise<Record<string, unknown>[] | { error: string }> {
    const result = await this.#api.calendarDoctor(slug, generation);
    if (!result.ok) return { error: result.error };
    const data = result.data as { checks?: unknown };
    return Array.isArray(data.checks) ? (data.checks as Record<string, unknown>[]) : [];
  }

  async createEvent(name: string, attrs: ValeaEventAttrs, generation: number): Promise<string | null> {
    const result = await this.#api.createValeaEvent(name, attrs, generation);
    if (!result.ok) return result.error;
    void this.refreshEvents();
    void this.refreshStatus();
    return null;
  }

  async updateEvent(name: string, attrs: ValeaEventAttrs, generation: number): Promise<string | null> {
    const result = await this.#api.updateValeaEvent(name, attrs, generation);
    if (!result.ok) return result.error;
    void this.refreshEvents();
    return null;
  }

  async deleteEvent(name: string, confirmation: string, generation: number): Promise<string | null> {
    const result = await this.#api.deleteValeaEvent(name, confirmation, generation);
    if (!result.ok) return result.error;
    void this.refreshEvents();
    void this.refreshStatus();
    return null;
  }

  /**
   * Enable is gated UI-side on `!feedEnabled`: the backend's enable action
   * on an already-enabled feed silently ROTATES the token (spec-compliant
   * — overwrite is rotation), so the panel only offers "Enable" when off
   * and an explicit "Rotate" once on.
   */
  async enableFeed(generation: number): Promise<string | null> {
    if (this.feedEnabled) return 'already_enabled';
    return this.#mintToken(this.#api.enableCalendarFeed(generation));
  }

  async rotateFeed(generation: number): Promise<string | null> {
    return this.#mintToken(this.#api.rotateCalendarFeedToken(generation));
  }

  async #mintToken(pending: ReturnType<CalendarApi['enableCalendarFeed']>): Promise<string | null> {
    const result = await pending;
    if (!result.ok) return result.error;
    const data = result.data as { token?: string };
    this.feedToken = data.token ?? null;
    this.feedEnabled = true;
    return null;
  }

  /** `calendar_status` push — upsert the source's row; a status flip also retries resupply. */
  handleCalendarStatus(payload: CalendarStatusPush): void {
    const status = normalizeCalendarSourceStatus(payload);
    const index = this.sources.findIndex((s) => s.source === status.source);
    if (index >= 0) {
      this.sources[index] = status;
    } else {
      this.sources = [...this.sources, status].sort((a, b) => a.source.localeCompare(b.source));
    }
    void resupplyCalendarUrls([status], this.#api);
  }

  /** `calendar_synced` push — a pass replaced the source's mirror; the visible range may have changed. */
  handleCalendarSynced(payload: CalendarSyncedPush): void {
    const index = this.sources.findIndex((s) => s.source === payload.source);
    if (index >= 0) this.sources[index] = { ...this.sources[index], eventCount: payload.event_count };
    void this.refreshEvents();
  }

  /** `calendar_local_changed` push — a valea event file was written/deleted (RPC-side or agent-side surfacing later via query). */
  handleCalendarLocalChanged(): void {
    void this.refreshEvents();
    void this.refreshStatus();
  }
}

export const calendarStore = new CalendarStore(api);

let calendarEventsWired = false;

/**
 * Attaches the three calendar push handlers to the already-joined
 * `workspace:events` channel — SINGLE CALL SITE: wired from `wireIcmEvents`
 * (`icm.svelte.ts`) beside `wireMailEvents`, for the same
 * one-join-per-topic reason. Idempotent against repeat calls.
 */
export function wireCalendarEvents(channel: Channel): void {
  if (calendarEventsWired) return;
  calendarEventsWired = true;

  channel.on('calendar_status', (payload: CalendarStatusPush) => calendarStore.handleCalendarStatus(payload));
  channel.on('calendar_synced', (payload: CalendarSyncedPush) => calendarStore.handleCalendarSynced(payload));
  channel.on('calendar_local_changed', () => calendarStore.handleCalendarLocalChanged());
}

/**
 * Silent feed-URL recovery — the calendar sibling of mail's
 * `resupplyCredentials`: a backend restart drops every engine's RAM-only
 * URL closure, so sources come back `urlPresent: false` even though the
 * URL still sits in the OS keychain under `<slug>:ics` (the write key of
 * `CalendarStore.addSource` step 3). Per-source and self-terminating: a
 * missing keychain entry just skips that source, and a successful resupply
 * flips `url_present` so the next push fails the filter. Browser: always 0.
 */
export async function resupplyCalendarUrls(
  sources: CalendarSourceStatus[],
  apiOverride: Pick<Api, 'setCalendarSourceUrl'> = api
): Promise<number> {
  if (!inDesktop()) return 0;

  let resupplied = 0;
  for (const status of sources) {
    if (!status.valid || status.urlPresent) continue;

    const workspaceId = workspaceStore.id;
    if (!workspaceId) continue;

    const url = await keychainGet(workspaceId, `${status.source}:ics`);
    if (url === null) continue;

    const generation = workspaceStore.generation ?? 0;
    const result = await apiOverride.setCalendarSourceUrl(status.source, url, generation);
    if (result.ok) resupplied += 1;
  }
  return resupplied;
}
