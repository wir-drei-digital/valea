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
});
