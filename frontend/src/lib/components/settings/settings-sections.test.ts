import { describe, it, expect } from 'vitest';
import { SETTINGS_SECTIONS, DEFAULT_SECTION } from './settings-sections';

describe('SETTINGS_SECTIONS', () => {
  it('lists Agent first, then Appearance', () => {
    expect(SETTINGS_SECTIONS.map((s) => s.id)).toEqual(['agent', 'appearance']);
  });

  it('gives every section a label and an icon', () => {
    for (const section of SETTINGS_SECTIONS) {
      expect(section.label.length).toBeGreaterThan(0);
      expect(section.icon).toBeTruthy();
    }
  });

  it('has unique ids', () => {
    const ids = SETTINGS_SECTIONS.map((s) => s.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it('defaults to a section that exists', () => {
    expect(SETTINGS_SECTIONS.some((s) => s.id === DEFAULT_SECTION)).toBe(true);
  });

  // The dialog opens on the agent pane; the harness command is the setting
  // people are sent here for by the "assistant isn't ready" copy.
  it('defaults to the agent section', () => {
    expect(DEFAULT_SECTION).toBe('agent');
  });
});
