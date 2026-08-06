import { describe, expect, it } from 'vitest';
import { normalizeTask } from './filters';
import { handoffPrompt, sessionLiveById } from './handoff';

describe('handoffPrompt', () => {
  it('names the task id, title, and the ledger file; includes only present fields', () => {
    const prompt = handoffPrompt(
      normalizeTask({
        id: 'tk_1',
        title: 'Rechnung stellen',
        notes: 'CHF 500',
        due: '2026-08-08',
        priority: 'high',
        source: '01_clients/CONTEXT.md'
      }),
      'w3d'
    );
    expect(prompt).toContain('tk_1');
    expect(prompt).toContain('Rechnung stellen');
    expect(prompt).toContain('CHF 500');
    expect(prompt).toContain('2026-08-08');
    expect(prompt).toContain('high');
    expect(prompt).toContain('01_clients/CONTEXT.md');
    expect(prompt).toContain('tasks.json');
  });
  it('omits absent fields without leaving labels behind', () => {
    const prompt = handoffPrompt(normalizeTask({ id: 'tk_2', title: 'Just a title' }), 'w3d');
    expect(prompt).not.toContain('Notes:');
    expect(prompt).not.toContain('Due:');
    expect(prompt).not.toContain('Priority:');
    expect(prompt).not.toContain('Source:');
  });
});

describe('sessionLiveById', () => {
  const groups = [
    {
      sessions: [
        { id: 's1', live: true },
        { id: 's2', live: false }
      ]
    }
  ];
  it('true/false when found, null when unknown', () => {
    expect(sessionLiveById(groups, 's1')).toBe(true);
    expect(sessionLiveById(groups, 's2')).toBe(false);
    expect(sessionLiveById(groups, 'gone')).toBeNull();
  });
});
