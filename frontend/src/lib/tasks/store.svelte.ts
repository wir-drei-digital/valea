import { api, type Api } from '../api/client';
import { workspaceStore } from '../stores/workspace.svelte';
import { normalizeTask, type TaskEntry } from './filters';

/**
 * Live view of both ICM ledgers for the `/tasks` route — `list_tasks` +
 * `list_schedules`, plus the mutating actions the two tabs drive
 * (tasks+schedules spec §RPC surface).
 *
 * Refresh is push-driven off the SAME `icm_changed` watcher event the knowledge
 * store consumes: the ledgers are plain files in user-owned ICM roots, so a
 * hand edit or an agent write is the normal way they change, and the watcher is
 * how this page learns about it. Wired by the route through
 * `icmStore.onIcmChanged` (the Today page's own pattern — one shared
 * `workspace:events` join, subscriber sets rather than a second racing
 * `channel.on`), never by a subscription inside this module: that would make a
 * leaf store import the tree store, and the watcher is UI-refresh-only by
 * contract (see the spec's §Write discipline).
 *
 * Everything the wire hands back keeps the FILE's own snake_case keys (the list
 * RPCs' entry arrays are unconstrained `:map`s by design — see
 * `Valea.Api.Tasks`' moduledoc), so the normalizers below read snake first and
 * accept a camel spelling as a fallback, exactly like `lib/today/cockpit.ts`.
 */
type TasksApi = Pick<
  Api,
  | 'listTasks'
  | 'createTask'
  | 'mutateTask'
  | 'archiveDone'
  | 'listSchedules'
  | 'createSchedule'
  | 'mutateSchedule'
  | 'deleteSchedule'
  | 'runScheduleNow'
  | 'scheduleRunHistory'
  | 'setSchedulerPaused'
>;

/** `Valea.Tasks.list/1`'s / `Valea.Schedules.File.load/1`'s per-ICM parse status — the calm malformed-file note reads off this. */
export type LedgerStatus = 'ok' | 'absent' | 'unreadable';

export type TaskIcm = {
  mountKey: string;
  icmName: string;
  status: LedgerStatus;
  tasks: TaskEntry[];
};

/** `Valea.Schedules.Entry`'s strict-execution verdict, verbatim. */
export type Disposition = 'executable' | 'paused' | 'not_executable';

export type ScheduleEntry = {
  /** `null` for an entry with no id — not executable and not addressable (spec §Leniency contract). */
  id: string | null;
  title: string | null;
  disposition: Disposition;
  /** The per-entry sentence for `not_executable` ("invalid cron: …", "duplicate id"); `null` otherwise. */
  reason: string | null;
  /** Raw cron expression as written — `humanizeCron` renders it. */
  cadence: string | null;
  timezone: string | null;
  /** `"prompt" | "command"`, or `null` when validation stopped before the payload. */
  payloadKind: string | null;
  paused: boolean;
  catchup: boolean;
  createdBy: string | null;
  /** ISO instant, executable entries only — a paused or non-executable entry has no next fire. */
  nextFire: string | null;
  lastOutcome: string | null;
  /** `first_seen_at` inside 24 h — the spec's subtle highlight for a newly registered/changed schedule. */
  registeredRecently: boolean;
};

export type ScheduleIcm = {
  mountKey: string;
  icmName: string;
  status: LedgerStatus;
  schedules: ScheduleEntry[];
};

export type ScheduleRun = {
  id: string | null;
  slot: string | null;
  firedAt: string | null;
  /** `"scheduled" | "manual" | "catchup"`. */
  trigger: string | null;
  /** The payload kind this run fired (`"prompt" | "command"`). */
  kind: string | null;
  outcome: string | null;
  durationMs: number | null;
  /** Prompt runs only — the transcript to link at `/chat?session=<id>`. */
  sessionId: string | null;
  /** Command runs only — captured output, already capped at 256 KiB backend-side. */
  output: string | null;
  coalescedCount: number | null;
};

/**
 * The workspace kill switch — TRI-state, never a boolean.
 * `"unreadable"` means `config/workspace.yaml` exists but does not parse, so
 * nobody can say what the user asked for: it fails CLOSED and its UI copy is a
 * config problem, NOT "you paused this".
 */
export type SchedulerPause = 'on' | 'off' | 'unreadable';

/** What a create/mutate answers with: the write landed, and here is whether the entry will actually fire. */
export type EditOutcome =
  | { ok: true; disposition: string | null; reason: string | null }
  | { ok: false; error: string };

export type SimpleOutcome = { ok: true } | { ok: false; error: string };
export type RunNowOutcome = { ok: true; runId: string } | { ok: false; error: string };

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/** Source-key-first lookup — the `lib/today/cockpit.ts` `pick/3` convention (see this module's header comment). */
function pick(raw: Record<string, unknown>, snake: string, camel: string): unknown {
  return raw[snake] !== undefined ? raw[snake] : raw[camel];
}

function ledgerStatus(value: unknown): LedgerStatus {
  return value === 'ok' || value === 'absent' || value === 'unreadable' ? value : 'unreadable';
}

function disposition(value: unknown): Disposition {
  return value === 'executable' || value === 'paused' ? value : 'not_executable';
}

function maps(value: unknown): Record<string, unknown>[] {
  return (Array.isArray(value) ? value : []).filter(
    (item): item is Record<string, unknown> => typeof item === 'object' && item !== null && !Array.isArray(item)
  );
}

export function normalizeTaskIcm(raw: Record<string, unknown>): TaskIcm {
  return {
    mountKey: str(pick(raw, 'mount_key', 'mountKey')) ?? '',
    icmName: str(pick(raw, 'icm_name', 'icmName')) ?? '',
    status: ledgerStatus(raw.status),
    tasks: maps(raw.tasks).map(normalizeTask)
  };
}

export function normalizeSchedule(raw: Record<string, unknown>): ScheduleEntry {
  return {
    id: str(raw.id),
    title: str(raw.title),
    disposition: disposition(raw.disposition),
    reason: str(raw.reason),
    cadence: str(raw.cadence),
    timezone: str(raw.timezone),
    payloadKind: str(pick(raw, 'payload_kind', 'payloadKind')),
    paused: raw.paused === true,
    catchup: raw.catchup === true,
    createdBy: str(pick(raw, 'created_by', 'createdBy')),
    nextFire: str(pick(raw, 'next_fire', 'nextFire')),
    lastOutcome: str(pick(raw, 'last_outcome', 'lastOutcome')),
    registeredRecently: pick(raw, 'registered_recently', 'registeredRecently') === true
  };
}

export function normalizeScheduleIcm(raw: Record<string, unknown>): ScheduleIcm {
  return {
    mountKey: str(pick(raw, 'mount_key', 'mountKey')) ?? '',
    icmName: str(pick(raw, 'icm_name', 'icmName')) ?? '',
    status: ledgerStatus(raw.status),
    schedules: maps(raw.schedules).map(normalizeSchedule)
  };
}

export function normalizeScheduleRun(raw: Record<string, unknown>): ScheduleRun {
  return {
    id: str(raw.id),
    slot: str(raw.slot),
    firedAt: str(pick(raw, 'fired_at', 'firedAt')),
    trigger: str(raw.trigger),
    kind: str(raw.kind),
    outcome: str(raw.outcome),
    durationMs: num(pick(raw, 'duration_ms', 'durationMs')),
    sessionId: str(pick(raw, 'session_id', 'sessionId')),
    output: str(raw.output),
    coalescedCount: num(pick(raw, 'coalesced_count', 'coalescedCount'))
  };
}

function pauseState(value: unknown): SchedulerPause {
  return value === 'on' || value === 'unreadable' ? value : 'off';
}

export class TasksStore {
  taskIcms: TaskIcm[] = $state([]);
  scheduleIcms: ScheduleIcm[] = $state([]);
  schedulerPaused: SchedulerPause = $state('off');
  /** True once a first successful load of EITHER list landed — drives the skeleton. */
  loaded = $state(false);
  /** Set only when the FIRST load failed; a failed background refresh keeps the last good payload. */
  failed = $state(false);

  #api: TasksApi;

  constructor(injected: TasksApi) {
    this.#api = injected;
  }

  /**
   * `explicit` exists for exactly one caller: `handleWorkspaceEvent`, where
   * `workspaceStore.generation` is DETERMINISTICALLY stale (the push carries the
   * incoming generation, `workspaceStore.refresh()` has not resolved yet) and
   * every generation-guarded read would be rejected with `workspace_changed`.
   * Same contract `IcmStore.refetch(generation)` keeps, for the same reason.
   */
  #generation(explicit?: number): number {
    return explicit ?? workspaceStore.generation ?? 0;
  }

  async refreshTasks(generation?: number): Promise<SimpleOutcome> {
    const result = await this.#api.listTasks({ generation: this.#generation(generation) });
    if (!result.ok) {
      if (!this.loaded) this.failed = true;
      return { ok: false, error: result.error };
    }

    const data = result.data as { icms?: unknown };
    this.taskIcms = maps(data.icms).map(normalizeTaskIcm);
    this.loaded = true;
    this.failed = false;
    return { ok: true };
  }

  async refreshSchedules(generation?: number): Promise<SimpleOutcome> {
    const result = await this.#api.listSchedules({ generation: this.#generation(generation) });
    if (!result.ok) {
      if (!this.loaded) this.failed = true;
      return { ok: false, error: result.error };
    }

    const data = result.data as { icms?: unknown; schedulerPaused?: unknown; scheduler_paused?: unknown };
    this.scheduleIcms = maps(data.icms).map(normalizeScheduleIcm);
    this.schedulerPaused = pauseState(pick(data as Record<string, unknown>, 'scheduler_paused', 'schedulerPaused'));
    this.loaded = true;
    this.failed = false;
    return { ok: true };
  }

  /** Both ledgers — what the route loads on mount and on every `icm_changed` push. */
  async refresh(generation?: number): Promise<void> {
    await Promise.all([this.refreshTasks(generation), this.refreshSchedules(generation)]);
  }

  /**
   * Clears back to cold-start shape. Called on every workspace event so the
   * previous workspace's ledgers are never mistaken for the new one's —
   * `RecentSessionsStore.reset()`'s contract, verbatim.
   */
  reset(): void {
    this.taskIcms = [];
    this.scheduleIcms = [];
    this.schedulerPaused = 'off';
    this.loaded = false;
    this.failed = false;
  }

  // -- tasks -----------------------------------------------------------------

  /** Quick-add. `fields` uses the FILE's own key names; `id`/`created_*` are stamped backend-side. */
  async createTask(mountKey: string, fields: Record<string, unknown>): Promise<SimpleOutcome> {
    const result = await this.#api.createTask({ mountKey, fields, generation: this.#generation() });
    if (!result.ok) return { ok: false, error: result.error };
    await this.refreshTasks();
    return { ok: true };
  }

  /**
   * Entry-level patch. The optimistic local update is deliberate: the write is
   * a read-patch-write through the per-ICM writer, and the `icm_changed` push
   * that follows is debounced 200 ms and best-effort by contract — a checkbox
   * that only moves once the watcher fires would feel broken. `refreshTasks`
   * still runs, so the file stays the authority.
   */
  async patchTask(mountKey: string, taskId: string, patch: Record<string, unknown>): Promise<SimpleOutcome> {
    this.#patchTaskLocally(mountKey, taskId, patch);
    const result = await this.#api.mutateTask({ mountKey, taskId, patch, generation: this.#generation() });
    await this.refreshTasks();
    return result.ok ? { ok: true } : { ok: false, error: result.error };
  }

  /** The row checkbox: complete (or reopen) a task. */
  async setTaskStatus(mountKey: string, taskId: string, status: string): Promise<SimpleOutcome> {
    return this.patchTask(mountKey, taskId, { status });
  }

  /** "Clear done" — one ICM, or every enabled one when `mountKey` is null. */
  async clearDone(mountKey: string | null): Promise<SimpleOutcome> {
    const result = await this.#api.archiveDone({
      ...(mountKey === null ? {} : { mountKey }),
      generation: this.#generation()
    });
    if (!result.ok) return { ok: false, error: result.error };
    await this.refreshTasks();
    return { ok: true };
  }

  #patchTaskLocally(mountKey: string, taskId: string, patch: Record<string, unknown>): void {
    this.taskIcms = this.taskIcms.map((icm) => {
      if (icm.mountKey !== mountKey) return icm;
      let patched = false;
      return {
        ...icm,
        tasks: icm.tasks.map((task) => {
          // First occurrence wins for addressing (duplicate ids degrade
          // softly — tasks are inert), same rule the backend patch applies.
          if (patched || task.id !== taskId) return task;
          patched = true;
          return normalizeTask({ ...task.raw, ...patch });
        })
      };
    });
  }

  // -- schedules -------------------------------------------------------------

  /**
   * Both write actions answer with the entry's freshly read-back
   * `disposition`/`reason`, so a composer or a pause toggle can say "saved, and
   * it will not fire: invalid cron" in the SAME reply. The local entry is
   * patched with that verdict immediately — the row must not keep advertising a
   * stale disposition while the re-list is in flight.
   */
  async createSchedule(mountKey: string, fields: Record<string, unknown>): Promise<EditOutcome> {
    const result = await this.#api.createSchedule({ mountKey, fields, generation: this.#generation() });
    if (!result.ok) return { ok: false, error: result.error };
    const data = result.data as { disposition?: unknown; reason?: unknown };
    await this.refreshSchedules();
    return { ok: true, disposition: str(data.disposition), reason: str(data.reason) };
  }

  async patchSchedule(
    mountKey: string,
    scheduleId: string,
    patch: Record<string, unknown>
  ): Promise<EditOutcome> {
    const result = await this.#api.mutateSchedule({
      mountKey,
      scheduleId,
      patch,
      generation: this.#generation()
    });
    if (!result.ok) return { ok: false, error: result.error };

    const data = result.data as { disposition?: unknown; reason?: unknown };
    const verdict = { disposition: str(data.disposition), reason: str(data.reason) };
    this.#patchScheduleLocally(mountKey, scheduleId, patch, verdict);
    await this.refreshSchedules();
    return { ok: true, ...verdict };
  }

  /** The pause toggle. `paused` is a FILE field — a hand edit or an agent edit can pause too. */
  async setSchedulePaused(mountKey: string, scheduleId: string, paused: boolean): Promise<EditOutcome> {
    return this.patchSchedule(mountKey, scheduleId, { paused });
  }

  async deleteSchedule(mountKey: string, scheduleId: string): Promise<SimpleOutcome> {
    const result = await this.#api.deleteSchedule({ mountKey, scheduleId, generation: this.#generation() });
    if (!result.ok) return { ok: false, error: result.error };
    await this.refreshSchedules();
    return { ok: true };
  }

  /** Run now — out-of-band, does not advance the anchor; refused for a non-executable or duplicate entry. */
  async runNow(mountKey: string, scheduleId: string): Promise<RunNowOutcome> {
    const result = await this.#api.runScheduleNow({ mountKey, scheduleId, generation: this.#generation() });
    if (!result.ok) return { ok: false, error: result.error };
    const data = result.data as { runId?: unknown; run_id?: unknown };
    return { ok: true, runId: str(pick(data as Record<string, unknown>, 'run_id', 'runId')) ?? '' };
  }

  async runHistory(
    mountKey: string,
    scheduleId: string,
    limit?: number
  ): Promise<{ ok: true; runs: ScheduleRun[] } | { ok: false; error: string }> {
    const result = await this.#api.scheduleRunHistory({
      mountKey,
      scheduleId,
      ...(limit === undefined ? {} : { limit }),
      generation: this.#generation()
    });
    if (!result.ok) return { ok: false, error: result.error };
    const data = result.data as { runs?: unknown };
    return { ok: true, runs: maps(data.runs).map(normalizeScheduleRun) };
  }

  /**
   * Pause-all. The reported state is READ BACK from the file, so a
   * `config/workspace.yaml` that turned unreadable under the write reports
   * `"unreadable"` rather than a clean pause.
   */
  async setSchedulerPaused(paused: boolean): Promise<SimpleOutcome> {
    const result = await this.#api.setSchedulerPaused({ paused, generation: this.#generation() });
    if (!result.ok) return { ok: false, error: result.error };
    const data = result.data as { schedulerPaused?: unknown; scheduler_paused?: unknown };
    this.schedulerPaused = pauseState(pick(data as Record<string, unknown>, 'scheduler_paused', 'schedulerPaused'));
    return { ok: true };
  }

  #patchScheduleLocally(
    mountKey: string,
    scheduleId: string,
    patch: Record<string, unknown>,
    verdict: { disposition: string | null; reason: string | null }
  ): void {
    this.scheduleIcms = this.scheduleIcms.map((icm) => {
      if (icm.mountKey !== mountKey) return icm;
      return {
        ...icm,
        schedules: icm.schedules.map((entry) => {
          if (entry.id !== scheduleId) return entry;
          return {
            ...entry,
            ...(typeof patch.paused === 'boolean' ? { paused: patch.paused } : {}),
            ...(typeof patch.title === 'string' ? { title: patch.title } : {}),
            ...(typeof patch.cron === 'string' ? { cadence: patch.cron } : {}),
            // A vanished entry answers `null`/`null` (a foreign writer deleted
            // it in the microseconds since); nothing to say about it, so the
            // row keeps the verdict it had rather than claiming executability.
            ...(verdict.disposition === null
              ? {}
              : { disposition: disposition(verdict.disposition), reason: verdict.reason })
          };
        })
      };
    });
  }
}

export const tasksStore = new TasksStore(api);
