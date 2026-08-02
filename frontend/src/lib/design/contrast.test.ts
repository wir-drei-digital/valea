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

describe.each(['light'] as const)('%s palette invariants', (palette) => {
  const p = readPalette(palette);

  it('the ink ramp gets quieter, heading through overline', () => {
    const order = ['ink-heading', 'ink-body', 'ink-secondary', 'ink-subtitle', 'ink-meta', 'ink-overline'];
    const ratios = order.map((t) => contrastRatio(p[t], p['paper-surface']));
    for (let i = 1; i < ratios.length; i++) {
      expect(ratios[i], `${order[i]} must be quieter than ${order[i - 1]}`).toBeLessThan(ratios[i - 1]);
    }
  });

  it('meta is the quietest ink allowed for meaningful text', () => {
    expect(contrastRatio(p['ink-meta'], p['paper-surface'])).toBeGreaterThanOrEqual(3.2);
  });

  // The order is the LIGHT palette's actual luminance order, which is not
  // the order the tokens are declared in: canvas is the desk, then the
  // recessed control track, then sidebar and panel chrome, then the content
  // surface, with card lifted highest. Dark must reproduce this ordering,
  // not merely be monotonic in some order of its own.
  it('the paper elevation chain gets lighter', () => {
    const chain = ['paper-canvas', 'paper-track', 'paper-sidebar', 'paper-panel', 'paper-surface', 'paper-card'];
    const lums = chain.map((t) => relativeLuminance(p[t]));
    for (let i = 1; i < lums.length; i++) {
      expect(lums[i], `${chain[i]} must be lighter than ${chain[i - 1]}`).toBeGreaterThan(lums[i - 1]);
    }
  });

  // Interaction fills are the one place the two themes legitimately move in
  // OPPOSITE directions: to pick a row out you darken light paper and
  // lighten dark paper. So the invariant is "differs from its surface",
  // never "is lighter than".
  it('interaction fills stand off the surface', () => {
    const surface = relativeLuminance(p['paper-surface']);
    const expectDarker = palette === 'light';
    for (const token of ['paper-pill', 'paper-nav-active', 'paper-tree-active']) {
      const delta = relativeLuminance(p[token]) - surface;
      expect(Math.abs(delta), `${token} must be distinguishable from the surface`).toBeGreaterThan(0.005);
      expect(delta < 0, `${token} must be ${expectDarker ? 'darker' : 'lighter'} than the surface`).toBe(expectDarker);
    }
  });

  // The invariant AccountSwitcher.svelte:38 asserts in a comment:
  // "every fill carries the white initial at contrast". The initials render
  // at 11px semibold — normal text, so the 4.5:1 threshold applies.
  it('every avatar fill carries the initial at 4.5:1', () => {
    const fg = p['primary-foreground'];
    for (const token of ['avatar-fill-1', 'avatar-fill-2', 'avatar-fill-3', 'avatar-fill-4']) {
      expect(p[token], `${token} must be defined`).toBeDefined();
      expect(contrastRatio(p[token], fg), `${token} vs primary-foreground`).toBeGreaterThanOrEqual(4.5);
    }
  });
});
