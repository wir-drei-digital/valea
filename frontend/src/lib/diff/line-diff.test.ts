import { describe, expect, it } from 'vitest';
import { lineDiff } from './line-diff';

describe('lineDiff', () => {
  it('marks unchanged, added, removed lines', () => {
    const { rows } = lineDiff('a\nb\nc', 'a\nx\nc');
    expect(rows).toEqual([
      { type: 'ctx', text: 'a' },
      { type: 'del', text: 'b' },
      { type: 'add', text: 'x' },
      { type: 'ctx', text: 'c' }
    ]);
  });

  it('handles pure insert and pure delete', () => {
    expect(lineDiff('', 'a\nb').rows).toEqual([
      { type: 'add', text: 'a' },
      { type: 'add', text: 'b' }
    ]);
    expect(lineDiff('a', '').rows).toEqual([{ type: 'del', text: 'a' }]);
  });

  it('caps output and flags truncation', () => {
    const big = Array.from({ length: 500 }, (_, i) => `l${i}`).join('\n');
    const out = lineDiff('', big, 100);
    expect(out.rows.length).toBe(100);
    expect(out.truncated).toBe(true);
  });

  it('skips LCS for oversized inputs and renders as del-then-add', () => {
    // 2100 lines each side: (2100+1) * (2100+1) = 4,410,201 > 4,000,000
    const bigA = Array.from({ length: 2100 }, (_, i) => `a${i}`).join('\n');
    const bigB = Array.from({ length: 2100 }, (_, i) => `b${i}`).join('\n');
    const out = lineDiff(bigA, bigB, 5000);

    // Should render as del-then-add: 2100 deletes + 2100 adds (capped at 5000)
    expect(out.truncated).toBe(true);
    expect(out.rows.length).toBe(4200);

    // Verify del-then-add structure: first 2100 should be deletes
    const firstRows = out.rows.slice(0, 2100);
    const allFirstAreDels = firstRows.every((r) => r.type === 'del');
    expect(allFirstAreDels).toBe(true);

    // Next 2100 should be adds
    const secondRows = out.rows.slice(2100);
    const allSecondAreAdds = secondRows.every((r) => r.type === 'add');
    expect(allSecondAreAdds).toBe(true);
  });
});
