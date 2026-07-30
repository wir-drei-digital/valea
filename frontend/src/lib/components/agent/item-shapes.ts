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
 *  - tool locations: `Connection.put_tool_locations/3`
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

export type ToolLocation = { path: string; relPath?: string; line?: number };

/**
 * `item.locations` as relayed by `Connection.put_tool_locations/3`:
 * `[{path, relPath?, line?}]`. `relPath` (ICM-root-relative) is present only
 * when the file lies inside the session's cwd — it is what file-open
 * affordances key off; entries without it render as plain text.
 */
export function toolLocations(item: AcpItemLike): ToolLocation[] {
  const raw = item.locations;
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((l): ToolLocation[] => {
    if (!l || typeof l !== 'object') return [];
    const rec = l as Record<string, unknown>;
    const path = rec.path;
    if (typeof path !== 'string' || path.length === 0) return [];
    return [
      {
        path,
        relPath: asPresentString(rec.relPath),
        line: typeof rec.line === 'number' ? rec.line : undefined
      }
    ];
  });
}

/**
 * The action verb of a redundant file-tool title, or undefined. "Read
 * CONTEXT.md" next to a `CONTEXT.md` location chip says everything twice, so
 * `ToolCallCard` collapses to a compact header (verb + chips, no title) when
 * the title is exactly one word followed by a path some location already
 * shows — equal to, or basename-suffix of, the location's path/relPath.
 * Only `read`/`edit` kinds qualify: their titles are adapter-derived
 * "<Verb> <path>" strings (the verb survives, so Write — which ACP files
 * under kind "edit" — still reads WRITE, not EDIT). Execute/search titles
 * are commands or patterns, never redundant with a chip.
 */
export function compactToolAction(
  kind: string,
  title: string,
  locations: ToolLocation[]
): string | undefined {
  if (kind !== 'read' && kind !== 'edit') return undefined;
  const match = /^([A-Za-z]+) (\S+)$/.exec(title);
  if (!match) return undefined;
  const [, verb, rest] = match;
  const covered = locations.some(
    (loc) =>
      rest === loc.path ||
      rest === loc.relPath ||
      loc.path.endsWith(`/${rest}`) ||
      (loc.relPath !== undefined && loc.relPath.endsWith(`/${rest}`))
  );
  return covered ? verb : undefined;
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

/**
 * The RAW ACP `configId` a `set_config_option` push must echo back —
 * `item.config_id` (`Connection.config_item_from_option/1`). The render
 * item's `id` is prefixed (`config-<...>`) for timeline uniqueness, and the
 * adapter rejects that prefixed form as an unknown option — which is
 * exactly how composer model/effort/mode changes used to error. Fallback
 * (an item from before the backend carried `config_id`, e.g. an attach
 * snapshot from a still-running older session): strip the known prefix.
 */
export function configWireId(item: AcpItemLike): string {
  const raw = item.config_id;
  if (typeof raw === 'string' && raw.length > 0) return raw;
  const id = typeof item.id === 'string' ? item.id : '';
  return id.startsWith('config-') ? id.slice('config-'.length) : id;
}

/**
 * The agent's own session title, from the `session_info` singleton
 * (`Connection.reduce_update/3`'s "session_info_update" clause — ACP
 * protocol-level, so any ACP agent that pushes titles feeds this, not just
 * the current harness). The item is upserted in place by id, and a
 * title-less info push replaces it wholesale — so only a present, non-empty
 * title counts; callers keep their previous value on undefined.
 */
export function sessionInfoTitle(items: AcpItemLike[]): string | undefined {
  const info = items.findLast((item) => item.type === 'session_info');
  return info ? asPresentString(info.title) : undefined;
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
export type ContextUsage = { used: number; max: number; fraction: number };

/**
 * The composer's context donut needs an explicit used/max pair. The `usage`
 * item has no fixed schema on our side (see `usageFields`), so this probes
 * the field names ACP-ish adapters actually send — camel and snake variants
 * of used/max tokens plus a context-window max — and returns undefined when
 * no such pair exists. Deliberately no fallback arithmetic over unrelated
 * counters (e.g. input+output tokens): a wrong donut is worse than none.
 */
export function contextUsage(item: AcpItemLike | undefined): ContextUsage | undefined {
  if (!item) return undefined;
  const used = firstCount(item, ['usedTokens', 'used_tokens', 'tokensUsed', 'used']);
  // `size` is what claude-agent-acp actually sends (`{used, size}` — its
  // usage_update pairs the used tokens with the model's context window size).
  const max = firstCount(item, [
    'maxTokens',
    'max_tokens',
    'tokenLimit',
    'contextWindow',
    'context_window',
    'max',
    'size'
  ]);
  if (used === undefined || max === undefined || max <= 0) return undefined;
  return { used, max, fraction: Math.min(used / max, 1) };
}

function firstCount(item: AcpItemLike, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = item[key];
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) return value;
  }
  return undefined;
}

export function usageFields(item: AcpItemLike | undefined): UsageField[] {
  if (!item) return [];
  return Object.entries(item).flatMap(([key, value]): UsageField[] => {
    if (key === 'id' || key === 'type' || key === 'seq') return [];
    const formatted = formatUsageValue(value);
    return formatted === undefined ? [] : [{ label: labelFor(key), value: formatted }];
  });
}
