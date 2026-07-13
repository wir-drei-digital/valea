import { describe, expect, it } from 'vitest';
import { buildMemoryReview, mountLabelFor } from './memory-review';
import type { QueueItemEnvelope, IcmPageData } from '$lib/api/client';

// Mirrors `Valea.Workflows.Runner.memory_envelope/5` (payload shape) and
// `queue.ex`'s `pending_memory!/5` test helper — snake_case, unconstrained
// `payload`/`proposed_action` maps riding through byte-for-byte, same
// raw-delivery contract every other queue envelope consumer relies on.
function memoryItem(overrides: {
  targetPath: string;
  baseSha256: string | null;
  contentMarkdown: string;
  riskLevel?: string;
  summary?: string;
  sources?: string[];
}): QueueItemEnvelope {
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
      proposed_action: {
        type: 'apply_page_content',
        target_path: overrides.targetPath,
        base_sha256: overrides.baseSha256,
        content_markdown: overrides.contentMarkdown
      }
    }
  };
}

function page(content: string, hash: string): IcmPageData {
  return {
    path: 'mounts/primary/Pricing/Current Pricing.md',
    title: 'Current Pricing',
    uri: 'icm://mounts/primary/Pricing/Current Pricing.md',
    content,
    hash,
    prosemirror: {},
    frontmatter: null
  };
}

describe('mountLabelFor', () => {
  it('labels an embedded mounts/<name>/... target as the mount name', () => {
    expect(mountLabelFor('mounts/primary/Pricing/Current Pricing.md')).toBe('primary');
  });

  it('labels an embedded target nested only one level as the mount name', () => {
    expect(mountLabelFor('mounts/primary/AGENTS.md')).toBe('primary');
  });

  it('labels an absolute (external) target as its full parent directory path', () => {
    expect(mountLabelFor('/abs/path/company-icm/Pricing/Current.md')).toBe('/abs/path/company-icm/Pricing');
  });

  it('labels a shallow absolute target as its immediate parent directory', () => {
    expect(mountLabelFor('/abs/path/company-icm/File.md')).toBe('/abs/path/company-icm');
  });

  it('falls back to the raw path for a malformed target matching neither shape', () => {
    expect(mountLabelFor('not-a-real-target.md')).toBe('not-a-real-target.md');
  });
});

describe('buildMemoryReview', () => {
  it('create mode (base_sha256 null): isCreate true, all-add rows, no stale-base warning', () => {
    const item = memoryItem({
      targetPath: 'mounts/primary/Decisions/2026-07.md',
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
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
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
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
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
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
      baseSha256: 'stale-hash',
      contentMarkdown: '# Pricing\n\n150\n'
    });

    const review = buildMemoryReview(item, current);

    expect(review.staleBase).toBe(true);
  });

  it('staleBase is false when the fetched page hash matches base_sha256', () => {
    const current = page('# Pricing\n\n100\n', 'matching-hash');
    const item = memoryItem({
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
      baseSha256: 'matching-hash',
      contentMarkdown: '# Pricing\n\n150\n'
    });

    const review = buildMemoryReview(item, current);

    expect(review.staleBase).toBe(false);
  });

  it('highRisk is true only when risk_level is "high"', () => {
    const high = memoryItem({
      targetPath: 'mounts/primary/AGENTS.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      riskLevel: 'high'
    });
    const medium = memoryItem({
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      riskLevel: 'medium'
    });

    expect(buildMemoryReview(high, null).highRisk).toBe(true);
    expect(buildMemoryReview(medium, null).highRisk).toBe(false);
  });

  it('carries targetPath, mountLabel, reason (payload.summary), and sources through', () => {
    const item = memoryItem({
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
      baseSha256: 'x',
      contentMarkdown: 'y',
      summary: 'Hourly rate changed to 150€',
      sources: ['mail:msg1', 'mounts/primary/Pricing/Current Pricing.md']
    });

    const review = buildMemoryReview(item, null);

    expect(review.targetPath).toBe('mounts/primary/Pricing/Current Pricing.md');
    expect(review.mountLabel).toBe('primary');
    expect(review.reason).toBe('Hourly rate changed to 150€');
    expect(review.sources).toEqual(['mail:msg1', 'mounts/primary/Pricing/Current Pricing.md']);
  });

  it('drops non-string sources defensively rather than crashing', () => {
    const item = memoryItem({
      targetPath: 'mounts/primary/Pricing/Current Pricing.md',
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
      targetPath: 'mounts/primary/Decisions/big.md',
      baseSha256: null,
      contentMarkdown: big
    });

    const review = buildMemoryReview(item, null);

    expect(review.truncated).toBe(true);
    expect(review.rows.length).toBe(400); // lineDiff's default cap
  });
});
