import { describe, expect, it } from 'vitest';
import { mailSummaryLine, normalizeCockpitToday, splitTrustClause } from './cockpit';

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
  while_you_were_away: ['Synced 9 emails from AI / Review · 7:00'],
  triage_workflow_path: 'mounts/primary/Workflows/New Inquiry Triage.md',
  triage_workflow_mount_key: 'primary',
  triage_workflow_relative_path: 'Workflows/New Inquiry Triage.md',
  distill_workflow_path: 'mounts/primary/Workflows/Distill Decisions.md',
  mail: { review_count: 3, inbox_count: 12, configured: true }
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
    expect(today.triageWorkflowPath).toBe('mounts/primary/Workflows/New Inquiry Triage.md');
    expect(today.triageWorkflowMountKey).toBe('primary');
    expect(today.triageWorkflowRelativePath).toBe('Workflows/New Inquiry Triage.md');
    expect(today.distillWorkflowPath).toBe('mounts/primary/Workflows/Distill Decisions.md');
    expect(today.mail).toEqual({ reviewCount: 3, inboxCount: 12, configured: true });
  });

  it('accepts camelCase keys as a fallback (Task 18: cockpit_today is now a fully typed/camelCased action)', () => {
    const today = normalizeCockpitToday({
      workspace: 'W',
      dateLabel: 'D',
      greeting: 'G',
      summary: 'S',
      schedule: [],
      preparedItems: [{ type: 't', title: 'x', summary: 's', usedSources: ['a'], primaryAction: 'p' }],
      openLoops: [],
      whileYouWereAway: [],
      triageWorkflowPath: 'mounts/primary/Workflows/New Inquiry Triage.md',
      triageWorkflowMountKey: 'primary',
      triageWorkflowRelativePath: 'Workflows/New Inquiry Triage.md',
      distillWorkflowPath: 'mounts/primary/Workflows/Distill Decisions.md',
      mail: { reviewCount: 1, inboxCount: 0, configured: false }
    });

    expect(today.dateLabel).toBe('D');
    expect(today.preparedItems[0].usedSources).toEqual(['a']);
    expect(today.preparedItems[0].secondaryAction).toBeUndefined();
    expect(today.triageWorkflowPath).toBe('mounts/primary/Workflows/New Inquiry Triage.md');
    expect(today.triageWorkflowMountKey).toBe('primary');
    expect(today.triageWorkflowRelativePath).toBe('Workflows/New Inquiry Triage.md');
    expect(today.distillWorkflowPath).toBe('mounts/primary/Workflows/Distill Decisions.md');
    expect(today.mail).toEqual({ reviewCount: 1, inboxCount: 0, configured: false });
  });

  it('tolerates missing collections, defaulting mail to zero/unconfigured and triageWorkflowPath/distillWorkflowPath to null', () => {
    const today = normalizeCockpitToday({ greeting: 'Hello.' });
    expect(today.schedule).toEqual([]);
    expect(today.preparedItems).toEqual([]);
    expect(today.openLoops).toEqual([]);
    expect(today.whileYouWereAway).toEqual([]);
    expect(today.triageWorkflowPath).toBeNull();
    expect(today.triageWorkflowMountKey).toBeNull();
    expect(today.triageWorkflowRelativePath).toBeNull();
    expect(today.distillWorkflowPath).toBeNull();
    expect(today.mail).toEqual({ reviewCount: 0, inboxCount: 0, configured: false });
  });

  it('normalizes an explicit null triageWorkflowPath (no enabled mount has a seeded triage workflow) to null, not the string "null"', () => {
    const today = normalizeCockpitToday({
      ...rawSnake,
      triage_workflow_path: null,
      triage_workflow_mount_key: null,
      triage_workflow_relative_path: null
    });
    expect(today.triageWorkflowPath).toBeNull();
    expect(today.triageWorkflowMountKey).toBeNull();
    expect(today.triageWorkflowRelativePath).toBeNull();
  });

  it('normalizes an explicit null distillWorkflowPath (no enabled mount has a seeded distill workflow yet — Task B9) to null, not the string "null"', () => {
    const today = normalizeCockpitToday({ ...rawSnake, distill_workflow_path: null });
    expect(today.distillWorkflowPath).toBeNull();
  });
});

describe('mailSummaryLine', () => {
  it('formats the review/inbox counts', () => {
    expect(mailSummaryLine({ reviewCount: 3, inboxCount: 12, configured: true })).toBe('3 to review · 12 in inbox');
  });

  it('formats zero counts plainly', () => {
    expect(mailSummaryLine({ reviewCount: 0, inboxCount: 0, configured: true })).toBe('0 to review · 0 in inbox');
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
