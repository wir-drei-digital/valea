import { describe, expect, it } from 'vitest';
import { normalizeCockpitToday, splitTrustClause } from './cockpit';

// Mirrors the seeded payload shape from backend/lib/valea/cockpit.ex —
// an unconstrained :map, so keys arrive snake_case over RPC.
const rawSnake = {
  workspace: 'Mara Lindt Coaching',
  date_label: 'Wednesday, 9 July · 8:31',
  greeting: 'Good morning, Mara.',
  summary:
    'Two sessions today, one new inquiry, one overdue invoice. I prepared three things overnight — nothing has been sent or changed without your approval.',
  schedule: [
    { time: '09:30', title: 'Admin hour', subtitle: "you're in it now", status: 'current' },
    { time: '15:00', title: 'Deep work', subtitle: 'no meetings — protected', status: null }
  ],
  prepared_items: [
    {
      type: 'reply_drafted',
      title: 'Priya Nair · new inquiry',
      summary: 'Good-fit inquiry.',
      used_sources: ['her email', 'Tone guide'],
      primary_action: 'Review draft',
      secondary_action: 'Snooze'
    }
  ],
  open_loops: [{ title: 'Send proposal to Priya', source: 'from her email · yesterday' }],
  while_you_were_away: ['Synced 9 emails from AI / Review · 7:00']
};

describe('normalizeCockpitToday', () => {
  it('maps snake_case payload keys into the typed camelCase shape', () => {
    const today = normalizeCockpitToday(rawSnake);

    expect(today.dateLabel).toBe('Wednesday, 9 July · 8:31');
    expect(today.greeting).toBe('Good morning, Mara.');
    expect(today.schedule).toHaveLength(2);
    expect(today.schedule[1].status).toBeNull();
    expect(today.preparedItems[0].usedSources).toEqual(['her email', 'Tone guide']);
    expect(today.preparedItems[0].primaryAction).toBe('Review draft');
    expect(today.preparedItems[0].secondaryAction).toBe('Snooze');
    expect(today.openLoops[0].source).toBe('from her email · yesterday');
    expect(today.whileYouWereAway).toHaveLength(1);
  });

  it('accepts camelCase keys as a fallback', () => {
    const today = normalizeCockpitToday({
      workspace: 'W',
      dateLabel: 'D',
      greeting: 'G',
      summary: 'S',
      schedule: [],
      preparedItems: [{ type: 't', title: 'x', summary: 's', usedSources: ['a'], primaryAction: 'p' }],
      openLoops: [],
      whileYouWereAway: []
    });

    expect(today.dateLabel).toBe('D');
    expect(today.preparedItems[0].usedSources).toEqual(['a']);
    expect(today.preparedItems[0].secondaryAction).toBeUndefined();
  });

  it('tolerates missing collections', () => {
    const today = normalizeCockpitToday({ greeting: 'Hello.' });
    expect(today.schedule).toEqual([]);
    expect(today.preparedItems).toEqual([]);
    expect(today.openLoops).toEqual([]);
    expect(today.whileYouWereAway).toEqual([]);
  });
});

describe('splitTrustClause', () => {
  it('splits the summary at the trust clause', () => {
    const { lead, trust } = splitTrustClause(rawSnake.summary);
    expect(lead.endsWith('overnight — ')).toBe(true);
    expect(trust).toBe('nothing has been sent or changed without your approval.');
  });

  it('returns everything as lead when the clause is absent', () => {
    const { lead, trust } = splitTrustClause('A quiet day.');
    expect(lead).toBe('A quiet day.');
    expect(trust).toBe('');
  });
});
