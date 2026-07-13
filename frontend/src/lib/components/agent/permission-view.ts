/**
 * Pure-logic view model for `PermissionCard.svelte` — same "no component
 * render harness; extract the logic instead" convention as `item-shapes.ts`.
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - `risk_tier`: `Valea.Acp` permission-item enrichment (B10) — `"high"` when
 *    the mount-relative target is `AGENTS.md`, `CLAUDE.md`, `icm.yaml`, or
 *    starts with `Workflows/`; else `"medium"`. Absent on non-file (e.g.
 *    shell command) permission requests.
 *  - `rawInput`: the ACP tool call's raw params, passed through unchanged —
 *    Edit tools carry `old_string`/`new_string` (+ `file_path`), Write tools
 *    carry `content` (+ `file_path`); anything else has neither, so no diff
 *    is derived and only `title`/`command` render.
 */
import { lineDiff, type DiffRow } from '$lib/diff/line-diff';

export type PermissionView = {
  title: string;
  command?: string;
  diff?: { path: string; rows: DiffRow[]; truncated: boolean; mode: 'edit' | 'write' };
  tier?: 'high' | 'medium';
};

const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);

export function derivePermissionView(item: Record<string, unknown>): PermissionView {
  const raw = (item.rawInput ?? {}) as Record<string, unknown>;
  const view: PermissionView = { title: str(item.title) ?? 'Permission request' };
  const command = str(item.command) ?? str(raw.command);
  if (command && command.trim().length > 0) view.command = command;

  const tier = str(item.risk_tier);
  if (tier === 'high' || tier === 'medium') view.tier = tier;

  const path = str(raw.file_path) ?? str(raw.path) ?? str(raw.filePath);
  const oldStr = str(raw.old_string);
  const newStr = str(raw.new_string);
  const content = str(raw.content);

  if (path && oldStr !== undefined && newStr !== undefined) {
    view.diff = { path, ...lineDiff(oldStr, newStr), mode: 'edit' };
  } else if (path && content !== undefined) {
    view.diff = { path, ...lineDiff('', content), mode: 'write' };
  }
  return view;
}

/** Calm, no-exclamation copy for the risk banner — matches spec's fixed high-tier line. */
export function tierCopy(tier: 'high' | 'medium'): string {
  return tier === 'high' ? 'Changes how your assistant behaves' : 'Edits your business memory';
}
