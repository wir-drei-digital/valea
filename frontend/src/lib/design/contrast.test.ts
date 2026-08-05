import { describe, it, expect } from 'vitest';
import { relativeLuminance, contrastRatio } from './contrast';
import { readPalette } from './tokens';
import { AVATAR_FILLS } from '../components/mail/avatar-fills';

// Derived from the palette the components actually cycle through, not written
// out again here — `avatar-fills.ts` promises this test guards additions, so a
// fifth `bg-avatar-fill-5` entry without a `--avatar-fill-5` token must FAIL
// the suite, not slip past a hardcoded list of four. Utility class → token
// name is the `bg-` prefix, per layout.css's `--color-*: var(--*)` mapping.
const AVATAR_TOKENS = AVATAR_FILLS.map((cls) => cls.replace(/^bg-/, ''));

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

describe.each(['light', 'dark'] as const)('%s palette invariants', (palette) => {
  const p = readPalette(palette);

  // FIRST, deliberately. `readPalette` reads ONE block and does not follow CSS
  // inheritance, so every token an invariant below reads must be declared in
  // that block — including ones deliberately identical to light. An absent
  // token comes back `undefined` and `relativeLuminance` throws on it, so the
  // failure would be a TypeError pointing into contrast.ts, naming no token.
  it('defines every token the invariants below read', () => {
    const required = [
      'paper-canvas', 'paper-track', 'paper-sidebar', 'paper-panel', 'paper-surface', 'paper-card',
      'paper-pill', 'paper-nav-active', 'paper-tree-active',
      'ink-heading', 'ink-body', 'ink-secondary', 'ink-subtitle', 'ink-meta', 'ink-overline',
      'primary-foreground', 'act', 'act-hover',
      ...AVATAR_TOKENS
    ];
    // Non-emptiness first: an absent or differently-formatted block yields {},
    // and every per-token loop below would then pass vacuously.
    expect(Object.keys(p).length, `${palette} palette must not be empty`).toBeGreaterThan(15);
    for (const t of required) {
      expect(p[t], `${palette} must define --${t}`).toBeDefined();
    }
  });

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

  // `UpdateNotice.svelte:38` renders real label text in --primary-foreground on
  // `hover:bg-act-hover`, so the HOVER fill carries normal text and owes the
  // same 4.5:1 as the resting fill — a threshold it is much easier to miss on,
  // because nothing shows it until the pointer is down on the control. Dark's
  // first draft (#3d9269) measured 3.77:1 for exactly that reason.
  it('the act fill carries its label at 4.5:1, resting and on hover', () => {
    const fg = p['primary-foreground'];
    for (const token of ['act', 'act-hover']) {
      expect(contrastRatio(p[token], fg), `${token} vs primary-foreground`).toBeGreaterThanOrEqual(4.5);
    }
  });

  // ...and hover must still read as "more". Same shape as the interaction
  // fills: light darkens to intensify, dark lightens, so the direction flips
  // but "differs, in the palette's own direction" does not. Without this, the
  // 4.5:1 rule above could be satisfied by making dark's hover DARKER than
  // --act, which on dark paper reads as the button receding on hover.
  it('the act hover reads as more, in the direction its paper allows', () => {
    const delta = relativeLuminance(p['act-hover']) - relativeLuminance(p['act']);
    expect(Math.abs(delta), 'act-hover must be distinguishable from act').toBeGreaterThan(0.005);
    expect(delta < 0, `act-hover must be ${palette === 'light' ? 'darker' : 'lighter'} than act`).toBe(
      palette === 'light'
    );
  });

  // The invariant AccountSwitcher.svelte:38 asserts in a comment:
  // "every fill carries the white initial at contrast". The initials render
  // at 11px semibold — normal text, so the 4.5:1 threshold applies.
  it('every avatar fill carries the initial at 4.5:1', () => {
    const fg = p['primary-foreground'];
    for (const token of AVATAR_TOKENS) {
      expect(p[token], `${token} must be defined`).toBeDefined();
      expect(contrastRatio(p[token], fg), `${token} vs primary-foreground`).toBeGreaterThanOrEqual(4.5);
    }
  });
});
