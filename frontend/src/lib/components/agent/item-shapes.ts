/**
 * Narrowing helpers for `AcpItem` (`$lib/stores/agent-session.svelte`) —
 * backend items are raw string-keyed maps (`Valea.Acp.Connection`'s render
 * items), typed `{ [k: string]: unknown }` past `id`/`type`/`seq`. Every
 * component under `agent/` reads item fields through these functions rather
 * than casting inline, so the "what shape does a `tool`/`permission`/`plan`
 * item actually have" knowledge lives in one place — and so it's
 * unit-testable without a component render harness (this repo has none; see
 * `editor/contract-rows.ts` for the same convention).
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - tool diff/output: `Valea.Acp.Connection.put_tool_content/2`
 *  - permission options/resolution: `Connection.request_permission
 *    dispatch_incoming/2` clause + `Connection.answer_permission/3`
 *  - plan entries: `Connection.plan_entries/1`
 *  - config item: `Connection.config_item_from_option/1`
 *  - turn stop_reason: `Connection.handle_response(state, :prompt, result)`
 */

export type AcpItemLike = { id: string; type: string; [k: string]: unknown };

export function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

export function asStringOr(value: unknown, fallback: string): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

/** Non-empty trimmed string, or undefined — for "only show this row if present" fields. */
export function asPresentString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value : undefined;
}

export type PermissionOption = { optionId: string; name: string; kind: string };

/**
 * `item.options`, as sent on the initial `session/request_permission` item —
 * `[{optionId, name, kind}]` (see `dispatch_incoming/2`'s permission clause).
 * A resolved item carries no `options` (the server's resolution echo is bare
 * `{id, type, resolved, outcome}` — see `answer_permission/3`), so this
 * correctly returns `[]` post-resolution and callers must not rely on
 * `options` being present once `resolved` is true.
 */
export function permissionOptions(item: AcpItemLike): PermissionOption[] {
  const raw = item.options;
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((o): PermissionOption[] => {
    if (!o || typeof o !== 'object') return [];
    const optionId = (o as Record<string, unknown>).optionId;
    if (typeof optionId !== 'string') return [];
    const name = (o as Record<string, unknown>).name;
    const kind = (o as Record<string, unknown>).kind;
    return [
      {
        optionId,
        name: typeof name === 'string' && name.length > 0 ? name : optionId,
        kind: typeof kind === 'string' ? kind : ''
      }
    ];
  });
}

/** A reject_once/reject_always option — never rendered as a green/filled action. */
export function isRejectKind(kind: string): boolean {
  return kind.startsWith('reject');
}

export type ToolDiff = { path?: string; oldText?: string; newText?: string };

/** `item.diff` as set by `put_tool_content/2`: `Map.take(diff, ["path", "oldText", "newText"])`. */
export function toolDiff(item: AcpItemLike): ToolDiff | undefined {
  const diff = item.diff;
  if (!diff || typeof diff !== 'object') return undefined;
  const d = diff as Record<string, unknown>;
  return {
    path: asPresentString(d.path),
    oldText: typeof d.oldText === 'string' ? d.oldText : undefined,
    newText: typeof d.newText === 'string' ? d.newText : undefined
  };
}

/** Splits diff old/new text into lines for a +/- render, dropping one trailing blank line. */
export function diffLines(text: string | undefined): string[] {
  if (!text) return [];
  return text.replace(/\n$/, '').split('\n');
}

export type PlanEntry = { text: string; status: string };

/** `item.entries`, as built by `Connection.plan_entries/1`: `[{text, status}]`. */
export function planEntries(item: AcpItemLike | undefined): PlanEntry[] {
  const raw = item?.entries;
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((e): PlanEntry[] => {
    if (!e || typeof e !== 'object') return [];
    const text = (e as Record<string, unknown>).text;
    const status = (e as Record<string, unknown>).status;
    return [
      {
        text: typeof text === 'string' ? text : '',
        status: typeof status === 'string' ? status : ''
      }
    ];
  });
}

function isDone(status: string): boolean {
  return status === 'completed' || status === 'done';
}

export type PlanProgress = { done: number; total: number; current: PlanEntry | undefined };

/** "n of m done · current step" — current is the in-progress entry, else the first not-done one. */
export function planProgress(entries: PlanEntry[]): PlanProgress {
  return {
    done: entries.filter((e) => isDone(e.status)).length,
    total: entries.length,
    current: entries.find((e) => e.status === 'in_progress') ?? entries.find((e) => !isDone(e.status))
  };
}

export function isPlanEntryDone(status: string): boolean {
  return isDone(status);
}

export type ConfigOption = { id: string; name: string };

/**
 * `item.options` on a `config` item — `Connection.config_item_from_option/1`
 * passes `option["options"] || []` through untouched from the adapter's
 * `configOptions[].options` (ACP session-config schema: `{value, name}` per
 * option; `value` is the id it round-trips through `setConfigOption`).
 */
export function configOptions(item: AcpItemLike): ConfigOption[] {
  const raw = item.options;
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((o): ConfigOption[] => {
    if (!o || typeof o !== 'object') return [];
    const rec = o as Record<string, unknown>;
    const id = rec.value ?? rec.id;
    if (typeof id !== 'string') return [];
    const name = rec.name;
    return [{ id, name: typeof name === 'string' && name.length > 0 ? name : id }];
  });
}

/** `item.current` on a `config` item — the selected option's id, or null if unset. */
export function configCurrent(item: AcpItemLike): string | null {
  const current = item.current;
  return typeof current === 'string' ? current : null;
}

export type UsageField = { label: string; value: string };

// camelCase/snake_case field name -> "Title Case" label, e.g. "inputTokens" -> "Input tokens".
function labelFor(key: string): string {
  const spaced = key
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/_/g, ' ')
    .toLowerCase();
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

function formatUsageValue(value: unknown): string | undefined {
  if (typeof value === 'number') return value.toLocaleString();
  if (typeof value === 'string' && value.length > 0) return value;
  return undefined;
}

/**
 * Renders whatever fields a `usage` item actually carries — the item is
 * `Map.merge(%{id, type}, Map.drop(u, ["sessionUpdate"]))` (see
 * `Connection.reduce_update(_, _, "usage_update")`), i.e. exactly the
 * adapter's own usage-update payload with no fixed schema on our side. No
 * derived totals or percentages are computed here — only fields the adapter
 * sent are shown, per "no invented math".
 */
export function usageFields(item: AcpItemLike | undefined): UsageField[] {
  if (!item) return [];
  return Object.entries(item).flatMap(([key, value]): UsageField[] => {
    if (key === 'id' || key === 'type') return [];
    const formatted = formatUsageValue(value);
    return formatted === undefined ? [] : [{ label: labelFor(key), value: formatted }];
  });
}
