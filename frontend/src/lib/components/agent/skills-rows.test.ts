import { describe, expect, test } from 'vitest';
import { actionFor, stateLabel, type SkillRow } from './skills-rows';

const base: SkillRow = {
  skillId: 'icm-architect',
  name: 'ICM Architect',
  description: 'd',
  sourceUrl: 'https://github.com/RinDig/icm-architect',
  license: 'MIT',
  pinned: 'sha',
  state: 'not_installed',
  installedVersion: null
};

describe('actionFor', () => {
  test('not_installed -> install', () => {
    expect(actionFor(base)).toBe('install');
  });

  test('installed -> remove', () => {
    expect(actionFor({ ...base, state: 'installed' })).toBe('remove');
  });

  test('update_available and edited -> update', () => {
    expect(actionFor({ ...base, state: 'update_available' })).toBe('update');
    expect(actionFor({ ...base, state: 'edited' })).toBe('update');
  });

  test('foreign -> null (display-only)', () => {
    expect(actionFor({ ...base, state: 'foreign' })).toBeNull();
  });
});

describe('stateLabel', () => {
  test('labels are plain language without exclamation marks', () => {
    for (const state of ['not_installed', 'foreign', 'edited', 'update_available', 'installed'] as const) {
      const label = stateLabel({ ...base, state });
      expect(label.length).toBeGreaterThan(0);
      expect(label).not.toContain('!');
    }
  });

  test('edited names the user, foreign names the hand-install', () => {
    expect(stateLabel({ ...base, state: 'edited' })).toBe('Edited by you');
    expect(stateLabel({ ...base, state: 'foreign' })).toBe('Installed by hand');
  });
});
