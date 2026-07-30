/**
 * Auto-open decision for agent replies that name a file (spec:
 * docs/superpowers/specs/2026-07-30-message-file-links-design.md §3).
 * Pure over the session store's ordered `items` so it is unit-testable
 * without a component harness — ChatView's effect owns the baseline
 * bookkeeping, the `icm_paths_exist` verification, and the actual open.
 */
import type { AcpItemLike } from './item-shapes';
import { asString } from './item-shapes';
import { messageFilePaths } from '$lib/markdown/agent-markdown';

/** How many turns the timeline holds — ChatView's baseline/increment signal. */
export function turnCount(items: AcpItemLike[]): number {
  let count = 0;
  for (const item of items) if (item.type === 'turn') count += 1;
  return count;
}

/**
 * The single openable path of the LATEST turn, or undefined. Fires only
 * when that turn (a) was delivered live — snapshot items carry no per-item
 * `seq`, only live pushes do (see AgentSessionStore's class doc), so a
 * seq-less turn is history replay and must never auto-open; (b) stopped
 * with `end_turn` (error/cancel turns carry other values); and (c) its
 * nearest preceding `message` item is an ASSISTANT message whose prose
 * names exactly one distinct candidate path (`messageFilePaths`). URLs are
 * never candidates — external navigation stays a deliberate click.
 */
export function latestTurnAutoOpenPath(items: AcpItemLike[]): string | undefined {
  let turnIndex = -1;
  for (let i = items.length - 1; i >= 0; i--) {
    if (items[i].type === 'turn') {
      turnIndex = i;
      break;
    }
  }
  if (turnIndex === -1) return undefined;
  const turn = items[turnIndex];
  if (typeof turn.seq !== 'number') return undefined;
  if (asString(turn.stop_reason) !== 'end_turn') return undefined;
  for (let i = turnIndex - 1; i >= 0; i--) {
    const item = items[i];
    if (item.type !== 'message') continue;
    if (asString(item.role) !== 'assistant') return undefined;
    const paths = messageFilePaths(asString(item.text));
    return paths.length === 1 ? paths[0] : undefined;
  }
  return undefined;
}
