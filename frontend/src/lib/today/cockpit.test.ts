import { describe, expect, it } from 'vitest';
import { mailSummaryLine, normalizeCockpitToday } from './cockpit';

// Mirrors the Spec-D cockpit payload shape from `backend/lib/valea/cockpit.ex`
// — an unconstrained-looking but fully typed :map, so keys arrive snake_case
// (see `Valea.Api.Cockpit`'s moduledoc for why the nested arrays still
// camelCase like every other typed action).
const rawSnake = {
  sections: [
    {
      mount_key: 'primary',
      icm_name: 'Mara Lindt Coaching',
      ok: true,
      updated_at: '2026-07-16T08:00:00Z',
      notes: 'Quiet day.',
      prepared: [{ title: 'Prep Lea', summary: 'One page', page: 'clients/lea.md' }],
      open_loops: [{ title: 'Send proposal', source: 'mail' }]
    }
  ],
  mail: { review_count: 3, inbox_count: 12, configured: true },
  recent_sessions: [
    { id: 'sess-1', title: 'Chat with Lea', started_at: '2026-07-16T08:00:00Z', status: 'ended', live: false }
  ]
};

describe('normalizeCockpitToday', () => {
  it('maps snake_case payload keys into the typed camelCase shape', () => {
    const today = normalizeCockpitToday(rawSnake);

    expect(today.sections).toHaveLength(1);
    const [section] = today.sections;
    expect(section.mountKey).toBe('primary');
    expect(section.icmName).toBe('Mara Lindt Coaching');
    expect(section.ok).toBe(true);
    expect(section.updatedAt).toBe('2026-07-16T08:00:00Z');
    expect(section.notes).toBe('Quiet day.');
    expect(section.prepared).toEqual([{ title: 'Prep Lea', summary: 'One page', page: 'clients/lea.md' }]);
    expect(section.openLoops).toEqual([{ title: 'Send proposal', source: 'mail' }]);

    expect(today.mail).toEqual({ reviewCount: 3, inboxCount: 12, configured: true });

    expect(today.recentSessions).toHaveLength(1);
    expect(today.recentSessions[0]).toEqual({
      id: 'sess-1',
      title: 'Chat with Lea',
      startedAt: '2026-07-16T08:00:00Z',
      status: 'ended',
      live: false
    });
  });

  it('accepts camelCase keys as a fallback', () => {
    const today = normalizeCockpitToday({
      sections: [
        {
          mountKey: 'primary',
          icmName: 'Studio',
          ok: true,
          updatedAt: '2026-07-16T08:00:00Z',
          notes: null,
          prepared: [],
          openLoops: []
        }
      ],
      mail: { reviewCount: 1, inboxCount: 0, configured: false },
      recentSessions: [
        { id: 'sess-2', title: 'Follow-up', startedAt: '2026-07-16T09:00:00Z', status: 'live', live: true }
      ]
    });

    expect(today.sections[0].mountKey).toBe('primary');
    expect(today.sections[0].icmName).toBe('Studio');
    expect(today.mail).toEqual({ reviewCount: 1, inboxCount: 0, configured: false });
    expect(today.recentSessions[0].live).toBe(true);
  });

  it('tolerates missing collections, defaulting to empty sections/sessions and zero/unconfigured mail', () => {
    const today = normalizeCockpitToday({});
    expect(today.sections).toEqual([]);
    expect(today.recentSessions).toEqual([]);
    expect(today.mail).toEqual({ reviewCount: 0, inboxCount: 0, configured: false });
  });

  it('drops wrong-typed fields to nil/[] rather than throwing', () => {
    const today = normalizeCockpitToday({
      sections: [
        {
          mount_key: 'primary',
          icm_name: 'Studio',
          ok: true,
          updated_at: 42,
          notes: ['not a string'],
          prepared: [{ title: 'ok', summary: 7 }, 'not-a-map'],
          open_loops: 'nope'
        }
      ],
      mail: { review_count: null, inbox_count: 'not-a-number', configured: 'yes' },
      recent_sessions: 'nope'
    });

    const [section] = today.sections;
    expect(section.updatedAt).toBeNull();
    expect(section.notes).toBeNull();
    expect(section.prepared).toEqual([{ title: 'ok', summary: null, page: null }]);
    expect(section.openLoops).toEqual([]);

    // `inbox_count: 'not-a-number'` would `Number(...)` to `NaN` without the
    // `Number.isFinite` guard — degrades to 0 like every other wrong-typed
    // field in this normalizer, rather than propagating NaN into the UI.
    expect(today.mail).toEqual({ reviewCount: 0, inboxCount: 0, configured: false });
    expect(today.recentSessions).toEqual([]);
  });

  it('renders a section with ok:false and no prepared/open-loop content, without dropping provenance', () => {
    const today = normalizeCockpitToday({
      sections: [
        {
          mount_key: 'primary',
          icm_name: 'Studio',
          ok: false,
          updated_at: null,
          notes: null,
          prepared: [],
          open_loops: []
        }
      ],
      mail: { review_count: 0, inbox_count: 0, configured: false },
      recent_sessions: []
    });

    const [section] = today.sections;
    expect(section.ok).toBe(false);
    expect(section.mountKey).toBe('primary');
    expect(section.icmName).toBe('Studio');
    expect(section.prepared).toEqual([]);
    expect(section.openLoops).toEqual([]);
  });

  it('normalizes a recent session with live:false to false, not falling back to true', () => {
    const today = normalizeCockpitToday({
      sections: [],
      mail: { review_count: 0, inbox_count: 0, configured: false },
      recent_sessions: [
        { id: 'sess-3', title: 'Ended session', started_at: '2026-07-16T07:00:00Z', status: 'ended', live: false }
      ]
    });

    expect(today.recentSessions[0].live).toBe(false);
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
