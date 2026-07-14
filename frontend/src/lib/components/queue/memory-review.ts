/**
 * Pure-logic view model for `MemoryUpdateReview.svelte` — same "no
 * component render harness; extract the logic instead" convention as
 * `permission-view.ts` (B11) and `queue-ops.ts`.
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - `item.risk_level`: server-computed risk tier (B1/B10) — `"high"` |
 *    `"medium"`, trusted, never re-derived client-side.
 *  - `item.payload`: `Valea.Workflows.Runner.memory_envelope/6` —
 *    `.kind === "memory_update"`, `.summary` (the manifest's `reason`),
 *    `.sources` (string array), `.proposed_action = {type:
 *    "apply_page_content", target: {locator, base_sha256 (64-hex | null,
 *    null means create), content_markdown}}` (Task 7.3 — `target` nests
 *    the stable ICM locator alongside the old flat sibling fields;
 *    verified against `queue.ex`'s own `pending_memory!/5` test helper).
 *    `.mount_key`/`.path`/`.icm_name` (Task 7.3 C5) are display-only
 *    fields the BACKEND resolves fresh from the locator against the
 *    current mount table (`Valea.Queue.memory_display_fields/2`, wired
 *    through `Valea.Queue.get/1`'s `enrich_item/2`) — `path` is the same
 *    ICM-relative string as `locator.path`, kept even when the mount no
 *    longer resolves; `mountKey`/`icmName` need a live, healthy mount.
 *  - `page`: the CURRENT on-disk page from `api.icmPage(mountKey,
 *    targetPath)` — the component passes `null` when it never fetched
 *    (create mode, or no `mountKey` to fetch by) or the fetch failed
 *    (edit mode, target unreadable); either way this module falls back to
 *    an all-add diff of the proposed content, same as create mode.
 */
import { lineDiff, type DiffRow } from '$lib/diff/line-diff';
import type { QueueItemEnvelope, IcmPageData } from '$lib/api/client';

export type MemoryReview = {
  targetPath: string;
  /** The ICM this target lives in (Task 7.3 C5) — `null` when the locator's ICM no longer names a healthy mount. Feeds `api.icmPage`/`knowledgeHref`. */
  mountKey: string | null;
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

export function buildMemoryReview(item: QueueItemEnvelope, page: IcmPageData | null): MemoryReview {
  const payload = (item.payload ?? {}) as Record<string, unknown>;
  const action = (payload.proposed_action ?? {}) as Record<string, unknown>;
  const target = (action.target ?? {}) as Record<string, unknown>;
  const locator = (target.locator ?? {}) as Record<string, unknown>;

  // `payload.path` (backend-enriched, Task 7.3 C5) is the primary source —
  // it stays populated even when the mount no longer resolves. Falling
  // back to the locator's own `path` covers an envelope handed to this
  // module WITHOUT going through `Valea.Queue.get/1`'s enrichment (e.g. a
  // test fixture built by hand).
  const targetPath = str(payload.path) || str(locator.path);
  const mountKey = typeof payload.mount_key === 'string' ? payload.mount_key : null;
  const icmName = typeof payload.icm_name === 'string' ? payload.icm_name : null;
  const baseSha256 = typeof target.base_sha256 === 'string' ? target.base_sha256 : null;
  const contentMarkdown = str(target.content_markdown);
  const isCreate = baseSha256 === null;

  // Edit mode with no page (fetch failed, no mountKey to fetch by, or
  // never attempted) still shows something reviewable: the proposed
  // content as an all-add block, same shape lineDiff('', x) naturally
  // produces for a create.
  const { rows, truncated } =
    isCreate || page === null ? lineDiff('', contentMarkdown) : lineDiff(page.content, contentMarkdown);

  const sources = Array.isArray(payload.sources)
    ? payload.sources.filter((s): s is string => typeof s === 'string')
    : [];

  return {
    targetPath,
    mountKey,
    // The ICM's own human-readable name, when a healthy mount resolved
    // one; falls back to the raw mount key, then to the target path
    // itself (defensive — every memory-update locator is an ICM one, so
    // this last resort should be unreachable in practice).
    mountLabel: icmName ?? mountKey ?? targetPath,
    isCreate,
    highRisk: item.risk_level === 'high',
    staleBase: !isCreate && page !== null && page.hash !== baseSha256,
    rows,
    truncated,
    reason: str(payload.summary),
    sources
  };
}
