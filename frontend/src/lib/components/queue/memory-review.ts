/**
 * Pure-logic view model for `MemoryUpdateReview.svelte` — same "no
 * component render harness; extract the logic instead" convention as
 * `permission-view.ts` (B11) and `queue-ops.ts`.
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - `item.risk_level`: server-computed risk tier (B1/B10) — `"high"` |
 *    `"medium"`, trusted, never re-derived client-side.
 *  - `item.payload`: `Valea.Workflows.Runner.memory_envelope/5` —
 *    `.kind === "memory_update"`, `.summary` (the manifest's `reason`),
 *    `.sources` (string array), `.proposed_action = {type:
 *    "apply_page_content", target_path, base_sha256 (64-hex | null,
 *    null means create), content_markdown}` — verified against
 *    `queue.ex`'s own `pending_memory!/5` test helper.
 *  - `page`: the CURRENT on-disk page from `api.icmPage(targetPath)` —
 *    the component passes `null` when it never fetched (create mode) or
 *    the fetch failed (edit mode, target unreadable); either way this
 *    module falls back to an all-add diff of the proposed content, same
 *    as create mode.
 */
import { lineDiff, type DiffRow } from '$lib/diff/line-diff';
import type { QueueItemEnvelope, IcmPageData } from '$lib/api/client';

export type MemoryReview = {
  targetPath: string;
  mountLabel: string;
  isCreate: boolean;
  highRisk: boolean;
  staleBase: boolean;
  rows: DiffRow[];
  truncated: boolean;
  reason: string;
  sources: string[];
};

const str = (v: unknown): string => (typeof v === 'string' ? v : '');

/**
 * Presentation-only mount label, derived from `targetPath` ALONE — this
 * module stays pure (no `Mounts.mount_for/2` round trip, no filesystem
 * lookup of "the first existing ancestor"). Two shapes (Spec A2's
 * physical-path vocabulary):
 *
 *  - embedded: `mounts/<name>/…` labels as `<name>` — the addressing
 *    scheme already names the mount, so no further parsing is needed.
 *  - external (absolute, by-reference): there is no shorter mount name
 *    derivable from the path text alone, so it labels as its own full
 *    parent directory path (everything before the final `/`) rather than
 *    guessing at a boundary this module has no way to verify.
 */
export function mountLabelFor(targetPath: string): string {
  const embedded = /^mounts\/([^/]+)(?:\/|$)/.exec(targetPath);
  if (embedded) return embedded[1];

  if (targetPath.startsWith('/')) {
    const idx = targetPath.lastIndexOf('/');
    return idx <= 0 ? '/' : targetPath.slice(0, idx);
  }

  // Defensive fallback for a malformed/unexpected target shape — show the
  // whole thing rather than an empty label.
  return targetPath;
}

export function buildMemoryReview(item: QueueItemEnvelope, page: IcmPageData | null): MemoryReview {
  const payload = (item.payload ?? {}) as Record<string, unknown>;
  const action = (payload.proposed_action ?? {}) as Record<string, unknown>;

  const targetPath = str(action.target_path);
  const baseSha256 = typeof action.base_sha256 === 'string' ? action.base_sha256 : null;
  const contentMarkdown = str(action.content_markdown);
  const isCreate = baseSha256 === null;

  // Edit mode with no page (fetch failed, or never attempted) still shows
  // something reviewable: the proposed content as an all-add block, same
  // shape lineDiff('', x) naturally produces for a create.
  const { rows, truncated } =
    isCreate || page === null ? lineDiff('', contentMarkdown) : lineDiff(page.content, contentMarkdown);

  const sources = Array.isArray(payload.sources)
    ? payload.sources.filter((s): s is string => typeof s === 'string')
    : [];

  return {
    targetPath,
    mountLabel: mountLabelFor(targetPath),
    isCreate,
    highRisk: item.risk_level === 'high',
    staleBase: !isCreate && page !== null && page.hash !== baseSha256,
    rows,
    truncated,
    reason: str(payload.summary),
    sources
  };
}
