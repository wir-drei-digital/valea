import { describe, it, expect } from 'vitest';
import { relativeLuminance, contrastRatio } from './contrast';
import { readPalette } from './tokens';

describe('contrast maths', () => {
  it('matches the WCAG reference points', () => {
    expect(relativeLuminance('#ffffff')).toBeCloseTo(1, 5);
    expect(relativeLuminance('#000000')).toBeCloseTo(0, 5);
    expect(contrastRatio('#ffffff', '#000000')).toBeCloseTo(21, 2);
  });

  it('is order-independent', () => {
    expect(contrastRatio('#2f5d48', '#fffefa')).toBeCloseTo(
      contrastRatio('#fffefa', '#2f5d48'),
      10
    );
  });

  it("reproduces the design system's documented light floor", () => {
    // DESIGN_SYSTEM.md:56 — #948A75 is the lightest ink allowed on #FBF8F1.
    expect(contrastRatio('#948a75', '#fbf8f1')).toBeCloseTo(3.22, 1);
  });

  it('accepts 3-digit hex', () => {
    expect(relativeLuminance('#fff')).toBeCloseTo(1, 5);
  });
});

describe('readPalette', () => {
  it('reads the light palette out of layout.css', () => {
    const light = readPalette('light');
    expect(light['paper-surface']).toBe('#fbf8f1');
    expect(light['ink-meta']).toBe('#948a75');
    expect(light['act']).toBe('#2f5d48');
    expect(light['primary-foreground']).toBe('#fffefa');
  });
});
