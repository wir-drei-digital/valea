import { describe, expect, test } from 'vitest';
import { eligibleOffer } from './skills-offer.svelte';
import type { SkillRow } from '$lib/components/agent/skills-rows';

const row = (state: SkillRow['state']): SkillRow => ({
  skillId: 'icm-architect',
  name: 'ICM Architect',
  description: 'd',
  sourceUrl: null,
  license: null,
  pinned: 'sha',
  state,
  installedVersion: null
});

describe('eligibleOffer', () => {
  test('not_installed and not dismissed -> offered', () => {
    expect(eligibleOffer([row('not_installed')], [])).toEqual(row('not_installed'));
  });

  test('dismissed -> null', () => {
    expect(eligibleOffer([row('not_installed')], ['icm-architect'])).toBeNull();
  });

  test('installed, update_available, edited, foreign -> null', () => {
    for (const state of ['installed', 'update_available', 'edited', 'foreign'] as const) {
      expect(eligibleOffer([row(state)], [])).toBeNull();
    }
  });

  test('first eligible row wins', () => {
    const other = { ...row('not_installed'), skillId: 'other' };
    expect(eligibleOffer([row('not_installed'), other], ['icm-architect'])).toEqual(other);
  });
});
