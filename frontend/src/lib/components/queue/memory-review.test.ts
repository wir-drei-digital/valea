import { describe, expect, it } from 'vitest';
import { buildMemoryReview } from './memory-review';
import type { QueueItemEnvelope, IcmPageData } from '$lib/api/client';

// Mirrors `Valea.Workflows.Runner.memory_envelope/6` (payload shape, Task
// 7.3 re-key) and `queue.ex`'s `pending_memory!/5` test helper —
// snake_case, unconstrained `payload`/`proposed_action` maps riding
// through byte-for-byte, same raw-delivery contract every other queue
// envelope consumer relies on. `mountKey`/`icmName` default to sensible
// values a healthy mount would have resolved (Task 7.3 C5) — tests that
// care about the unresolved case pass `mountKey: null` explicitly.
function memoryItem(overrides: {
  targetPath: string;
  baseSha256: string | null;
  contentMarkdown: string;
  riskLevel?: string;
  summary?: string;
  sources?: string[];
  mountKey?: string | null;
  icmName?: string | null;
  icmId?: string;
}): QueueItemEnvelope {
  const icmId = overrides.icmId ?? 'icm-1';
  const mountKey = overrides.mountKey === undefined ? 'primary' : overrides.mountKey;
  const icmName = overrides.icmName === undefined ? 'Primary' : overrides.icmName;

  return {
    schema: 'queue_item/v2',
    run_id: 'run1-m1',
    session_id: 'sess1',
    workflow: 'mounts/primary/Workflows/New Inquiry Triage.md',
    workflow_hash: 'hash',
    input: 'input',
    input_hash: 'hash',
    risk_level: overrides.riskLevel ?? 'medium',
    approval: {},
    created_at: '2026-07-12T00:00:00Z',
    payload: {
      title: 'Update x',
      summary: overrides.summary ?? 'why',
      kind: 'memory_update',
      sources: overrides.sources ?? [],
      mount_key: mountKey,
      path: overrides.targetPath,
      icm_name: mountKey === null ? null : icmName,
      proposed_action: {
        type: 'apply_page_content',
        target: {
          locator: { kind: 'icm', icm_id: icmId, path: overrides.targetPath },
          base_sha256: overrides.baseSha256,
          content_markdown: overrides.contentMarkdown
        }
      }
    }
  };
}

function page(content: string, hash: string): IcmPageData {
  return {
    path: 'Pricing/Current Pricing.md',
    title: 'Current Pricing',
    uri: 'icm://mounts/primary/Pricing/Current Pricing.md',
    content,
    hash,
    prosemirror: {},
    frontmatter: null
  };
}

describe('buildMemoryReview', () => {
  it('create mode (base_sha256 null): isCreate true, all-add rows, no stale-base warning', () => {
    const item = memoryItem({
      targetPath: 'Decisions/2026-07.md',
      baseSha256: null,
      contentMarkdown: '# Decisions\n\nFirst one\n'
    });

    const review = buildMemoryReview(item, null);

    expect(review.isCreate).toBe(true);
    expect(review.staleBase).toBe(false);
    expect(review.truncated).toBe(false);
    expect(review.rows).toEqual([
      { type: 'add', text: '# Decisions' },
      { type: 'add', text: '' },
      { type: 'add', text: 'First one' },
      { type: 'add', text: '' }
    ]);
  });

  it('edit mode: diffs the fetched page content against the proposed content', () => {
    const base = page('# Pricing\n\n100\n', 'aaa');
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'aaa',
      contentMarkdown: '# Pricing\n\n150\n'
    });

    const review = buildMemoryReview(item, base);

    expect(review.isCreate).toBe(false);
    expect(review.staleBase).toBe(false);
    expect(review.rows).toEqual([
      { type: 'ctx', text: '# Pricing' },
      { type: 'ctx', text: '' },
      { type: 'del', text: '100' },
      { type: 'add', text: '150' },
      { type: 'ctx', text: '' }
    ]);
  });

  it('edit mode with page fetch failure (page null): falls back to all-add of the proposed content', () => {
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'aaa',
      contentMarkdown: '# Pricing\n\n150\n'
    });

    const review = buildMemoryReview(item, null);

    expect(review.isCreate).toBe(false);
    // No page to compare hashes against, so staleBase can't be asserted true.
    expect(review.staleBase).toBe(false);
    expect(review.rows.every((r) => r.type === 'add')).toBe(true);
  });

  it('staleBase is true when the fetched page hash no longer matches base_sha256', () => {
    const current = page('# Pricing\n\n999\n', 'current-hash');
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'stale-hash',
      contentMarkdown: '# Pricing\n\n150\n'
    });

    const review = buildMemoryReview(item, current);

    expect(review.staleBase).toBe(true);
  });

  it('staleBase is false when the fetched page hash matches base_sha256', () => {
    const current = page('# Pricing\n\n100\n', 'matching-hash');
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'matching-hash',
      contentMarkdown: '# Pricing\n\n150\n'
    });

    const review = buildMemoryReview(item, current);

    expect(review.staleBase).toBe(false);
  });

  it('highRisk is true only when risk_level is "high"', () => {
    const high = memoryItem({
      targetPath: 'AGENTS.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      riskLevel: 'high'
    });
    const medium = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      riskLevel: 'medium'
    });

    expect(buildMemoryReview(high, null).highRisk).toBe(true);
    expect(buildMemoryReview(medium, null).highRisk).toBe(false);
  });

  it('carries targetPath, mountKey, mountLabel (icmName), reason (payload.summary), and sources through', () => {
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      summary: 'Hourly rate changed to 150€',
      sources: ['mail:msg1', 'Pricing/Current Pricing.md'],
      mountKey: 'primary',
      icmName: 'Primary'
    });

    const review = buildMemoryReview(item, null);

    expect(review.targetPath).toBe('Pricing/Current Pricing.md');
    expect(review.mountKey).toBe('primary');
    expect(review.mountLabel).toBe('Primary');
    expect(review.reason).toBe('Hourly rate changed to 150€');
    expect(review.sources).toEqual(['mail:msg1', 'Pricing/Current Pricing.md']);
  });

  it('mountKey/mountLabel are null/fall back when the locator\'s ICM no longer names a healthy mount', () => {
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      mountKey: null,
      icmName: null
    });

    const review = buildMemoryReview(item, null);

    expect(review.mountKey).toBeNull();
    // No icmName, no mountKey — falls all the way back to the target path.
    expect(review.mountLabel).toBe('Pricing/Current Pricing.md');
  });

  it('falls back to the locator\'s own path when payload.path is absent (envelope built without backend enrichment)', () => {
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y'
    });
    // Simulate a hand-built envelope that never went through
    // `Valea.Queue.get/1`'s `enrich_item/2` — `payload.path` absent, only
    // the locator's own `path` survives.
    delete (item.payload as Record<string, unknown>).path;

    const review = buildMemoryReview(item, null);

    expect(review.targetPath).toBe('Pricing/Current Pricing.md');
  });

  it('drops non-string sources defensively rather than crashing', () => {
    const item = memoryItem({
      targetPath: 'Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y'
    });
    (item.payload as Record<string, unknown>).sources = ['ok', 5, null];

    expect(buildMemoryReview(item, null).sources).toEqual(['ok']);
  });

  it('defaults gracefully to a create-shaped empty review when proposed_action is missing entirely', () => {
    const item: QueueItemEnvelope = {
      schema: 'queue_item/v2',
      run_id: 'run1-m1',
      session_id: 'sess1',
      workflow: 'mounts/primary/Workflows/New Inquiry Triage.md',
      workflow_hash: 'hash',
      input: 'input',
      input_hash: 'hash',
      risk_level: 'medium',
      approval: {},
      created_at: '2026-07-12T00:00:00Z',
      payload: { kind: 'memory_update' }
    };

    const review = buildMemoryReview(item, null);

    expect(review.targetPath).toBe('');
    expect(review.mountKey).toBeNull();
    expect(review.mountLabel).toBe('');
    expect(review.isCreate).toBe(true);
    expect(review.staleBase).toBe(false);
    expect(review.rows).toEqual([]);
    expect(review.reason).toBe('');
    expect(review.sources).toEqual([]);
  });

  it('truncated propagates from lineDiff rather than being recomputed (create mode, oversized content)', () => {
    const big = Array.from({ length: 500 }, (_, i) => `line ${i}`).join('\n');
    const item = memoryItem({
      targetPath: 'Decisions/big.md',
      baseSha256: null,
      contentMarkdown: big
    });

    const review = buildMemoryReview(item, null);

    expect(review.truncated).toBe(true);
    expect(review.rows.length).toBe(400); // lineDiff's default cap
  });
});
