import { describe, expect, it } from 'vitest';
import type { AcpItemLike } from './item-shapes';
import { deriveFileActivity, splitPathName } from './file-activity';

let nextId = 0;
function tool(over: Partial<AcpItemLike> & { [k: string]: unknown } = {}): AcpItemLike {
  return { id: `t${nextId++}`, type: 'tool', status: 'completed', ...over };
}
const loc = (relPath: string, path = `/ws/${relPath}`) => ({ path, relPath });

describe('deriveFileActivity', () => {
  it('one row per file, deduped across calls, read badge', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('notes/a.md')] }),
      tool({ kind: 'read', locations: [loc('notes/a.md')] })
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ key: 'notes/a.md', kindBadge: 'read', read: true, edited: false });
    expect(rows[0].edits).toHaveLength(0);
  });

  it('read then edit promotes to edited; diff lands in edits', () => {
    const diff = { path: 'notes/a.md', oldText: 'x\n', newText: 'y\n' };
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('notes/a.md')] }),
      tool({ kind: 'edit', locations: [loc('notes/a.md')], diff })
    ]);
    expect(rows[0].kindBadge).toBe('edited');
    expect(rows[0].read).toBe(true);
    expect(rows[0].edits).toEqual([{ diff: { path: 'notes/a.md', oldText: 'x\n', newText: 'y\n' } }]);
  });

  it('excludes failed and running calls', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', status: 'failed', locations: [loc('a.md')], diff: { oldText: 'x', newText: 'y' } }),
      tool({ kind: 'edit', status: 'in_progress', locations: [loc('b.md')] })
    ]);
    expect(rows).toHaveLength(0);
  });

  it('created: first edit diff with empty oldText and non-empty newText', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('new.md')], diff: { path: 'new.md', newText: 'hello\n' } })
    ]);
    expect(rows[0].kindBadge).toBe('created');
  });

  it('created inference misses empty-file creation (documented): stays edited', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('empty.md')], diff: { path: 'empty.md' } })
    ]);
    expect(rows[0].kindBadge).toBe('edited');
  });

  it('delete/move kinds badge deleted/renamed, no edits entries', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'delete', locations: [loc('gone.md')] }),
      tool({ kind: 'move', locations: [loc('to.md')] })
    ]);
    expect(rows.map((r) => r.kindBadge).sort()).toEqual(['deleted', 'renamed']);
    expect(rows.every((r) => r.edits.length === 0)).toBe(true);
  });

  it('badge precedence: delete beats edit beats read', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('a.md')] }),
      tool({ kind: 'edit', locations: [loc('a.md')], diff: { oldText: 'x', newText: 'y' } }),
      tool({ kind: 'delete', locations: [loc('a.md')] })
    ]);
    expect(rows[0].kindBadge).toBe('deleted');
  });

  it('multi-location edit: diff attaches to the diff.path match, others get diff-less entries', () => {
    const diff = { path: 'b.md', oldText: 'x', newText: 'y' };
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('a.md'), loc('b.md')], diff })
    ]);
    const a = rows.find((r) => r.key === 'a.md')!;
    const b = rows.find((r) => r.key === 'b.md')!;
    expect(b.edits).toEqual([{ diff }]);
    expect(a.edits).toEqual([{}]);
  });

  it('multi-location edit without a diff.path match: first location gets the diff', () => {
    const diff = { oldText: 'x', newText: 'y' };
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('a.md'), loc('b.md')], diff })
    ]);
    expect(rows.find((r) => r.key === 'a.md')!.edits).toEqual([{ diff }]);
  });

  it('no locations but diff.path: synthesizes a non-openable row', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', diff: { path: '/abs/x.md', oldText: 'a', newText: 'b' } })
    ]);
    expect(rows[0]).toMatchObject({ key: '/abs/x.md', relPath: undefined, kindBadge: 'edited' });
  });

  it('edit call with locations but no diff payload: edits entry preserved without diff', () => {
    const rows = deriveFileActivity([tool({ kind: 'edit', locations: [loc('a.md')] })]);
    expect(rows[0].edits).toEqual([{}]);
  });

  it('non-tool items and non-file kinds are ignored', () => {
    const rows = deriveFileActivity([
      { id: 'm1', type: 'message' },
      tool({ kind: 'execute', locations: [loc('a.md')] }),
      tool({ kind: 'search', locations: [loc('b.md')] })
    ]);
    expect(rows).toHaveLength(0);
  });

  it('sort: changed first, then most-recent lastIndex desc within groups', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('r1.md')] }),
      tool({ kind: 'edit', locations: [loc('e1.md')], diff: { oldText: 'x', newText: 'y' } }),
      tool({ kind: 'read', locations: [loc('r2.md')] }),
      tool({ kind: 'edit', locations: [loc('e2.md')], diff: { oldText: 'x', newText: 'y' } })
    ]);
    expect(rows.map((r) => r.key)).toEqual(['e2.md', 'e1.md', 'r2.md', 'r1.md']);
  });

  it('outside-mount row keeps verbatim path, no relPath', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [{ path: 'C:\\other\\doc.md' }] })
    ]);
    expect(rows[0]).toMatchObject({ key: 'C:\\other\\doc.md', relPath: undefined, name: 'doc.md', dir: 'C:\\other' });
  });
});

describe('splitPathName', () => {
  it('splits on forward slash', () => {
    expect(splitPathName('notes/deep/a.md')).toEqual({ name: 'a.md', dir: 'notes/deep' });
  });
  it('splits on backslash', () => {
    expect(splitPathName('C:\\ws\\a.md')).toEqual({ name: 'a.md', dir: 'C:\\ws' });
  });
  it('no separator: whole string is the name', () => {
    expect(splitPathName('a.md')).toEqual({ name: 'a.md', dir: '' });
  });
});
