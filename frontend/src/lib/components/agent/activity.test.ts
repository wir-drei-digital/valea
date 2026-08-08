import { describe, it, expect } from 'vitest';
import { runningTools, activityLabel } from './activity';

const tool = (id: string, status: string, title = id) => ({ id, type: 'tool', status, title });

describe('runningTools', () => {
  it('keeps only pending and in-progress tools', () => {
    const items = [
      tool('a', 'completed'),
      tool('b', 'in_progress'),
      tool('c', 'pending'),
      tool('d', 'failed')
    ];
    expect(runningTools(items).map((t) => t.id)).toEqual(['b', 'c']);
  });

  it('ignores everything that is not a tool', () => {
    const items = [
      { id: 'm', type: 'message', status: 'in_progress' },
      { id: 'p', type: 'plan', status: 'in_progress' },
      tool('t', 'in_progress')
    ];
    expect(runningTools(items).map((t) => t.id)).toEqual(['t']);
  });

  it('keeps the timeline order it was given', () => {
    expect(runningTools([tool('x', 'pending'), tool('y', 'in_progress')]).map((t) => t.id)).toEqual([
      'x',
      'y'
    ]);
  });

  it('falls back to a generic title rather than rendering an empty row', () => {
    expect(runningTools([{ id: 'z', type: 'tool', status: 'in_progress' }])[0].title).toBe('Working…');
  });

  it('is empty for an empty timeline', () => {
    expect(runningTools([])).toEqual([]);
  });
});

describe('activityLabel', () => {
  it('says Working… when nothing is running', () => {
    expect(activityLabel([])).toBe('Working…');
  });

  it('names the most recently started work', () => {
    expect(
      activityLabel([
        { id: 'a', title: 'Read CONTEXT.md' },
        { id: 'b', title: 'Researching auth flow' }
      ])
    ).toBe('Researching auth flow');
  });
});
