# Settings Shell and Dark Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the sidebar's "Agent settings" modal into a generic Settings dialog with an internal nav, and add a warm "night paper" dark theme selectable as Light / Dark / System.

**Architecture:** Three stages that each leave the app working. Stage A migrates tokens that are *correct today but wrong once a second palette exists* — a deliberate no-op in light mode, so it can be verified alone. Stage B restructures the settings dialog around a data registry of sections. Stage C defines the `.dark` token block, a pre-paint theme script, and the Appearance section that drives them.

**Tech Stack:** Svelte 5 (runes), SvelteKit (adapter-static, SPA), Tailwind 4 (`@theme inline`), shadcn-svelte + bits-ui, Vitest (Node env, no DOM), Tauri v2 desktop shell, Phoenix serving the built SPA.

**Spec:** `docs/superpowers/specs/2026-08-02-settings-shell-and-dark-mode-design.md`

## Global Constraints

- **Working directory is `frontend/`** for every command unless a step says otherwise. One task touches `backend/`.
- **Never run prettier.** This frontend has no prettier config; running it bare reformats the entire repo. Match surrounding style by hand.
- **Verification after every task:** `npx vitest run` (all must pass) and `npm run check` (0 errors, 0 warnings).
- **Vitest has no DOM.** `src/**/*.test.ts` runs in Node with no `document`, `localStorage`, or `matchMedia`. Stub what you need per test and delete the stub in `afterEach`.
- **Rune-level tests** (`$state`/`$effect`) must be named `*.test.svelte.ts`; they run under the `runes` vitest project with `vitest-env-svelte-client.ts`. A plain `.test.ts` cannot use runes (`$effect is not defined`), and an SSR-compiled one compiles `$effect` away and passes vacuously.
- **Storage access is always guarded** — `typeof localStorage !== 'undefined'`, plus `try`/`catch` around every call. Absent or throwing storage means the preference is session-local, never an error. Follow `src/lib/stores/recent-pages.ts`.
- **Store write paths must not read reactive state untracked-free.** Per issue #4, a `$state` read on a write path subscribes the caller. Use `untrack` as `tree-state.svelte.ts` does.
- **Colour reaches components through tokens, never literals**, and a token is chosen for its **role**, not its appearance. Ink on a consequence fill is `--primary-foreground`, never `--paper-card`.
- **Copy rule:** the settings surface is called **"Settings"**; the agent pane is **"Settings → Agent"**. No user-facing string says "Agent settings" after Task 7.
- **Commit after every task.** Conventional commits (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`), ending with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```

---

## File Structure

**Stage A — role tokens (light-mode no-op)**

| File | Responsibility |
|---|---|
| `src/lib/design/contrast.ts` (create) | Pure WCAG relative-luminance + contrast-ratio maths |
| `src/lib/design/tokens.ts` (create) | Parses `layout.css` custom properties into a `{name: hex}` map, per palette |
| `src/lib/design/contrast.test.ts` (create) | Asserts the palette's contrast invariants |
| `src/lib/components/mail/avatar-fills.ts` (create) | The avatar fill palette as data, with its own token names |
| `src/routes/layout.css` (modify) | Adds avatar fill tokens |
| 7 component files (modify) | On-accent foregrounds move to `--primary-foreground` |

**Stage B — settings shell**

| File | Responsibility |
|---|---|
| `src/lib/components/settings/settings-sections.ts` (create) | Section registry: ids, labels, icons |
| `src/lib/components/settings/settings-sections.test.ts` (create) | Registry invariants |
| `src/lib/components/settings/SettingsNav.svelte` (create) | The nav column inside the dialog |
| `src/lib/components/settings/SettingsModal.svelte` (create) | Dialog shell: nav + section pane |
| `src/lib/components/settings/sections/AgentSection.svelte` (create) | Body of the old `HarnessSettingsModal` |
| `src/lib/components/agent/HarnessSettingsModal.svelte` (delete) | Replaced |

**Stage C — dark mode**

| File | Responsibility |
|---|---|
| `src/lib/stores/theme.ts` (create) | `ThemePreference`, `resolveTheme`, storage key — pure, no runes |
| `src/lib/stores/theme.svelte.ts` (create) | `ThemeStore`: preference, persistence, `matchMedia`, DOM application |
| `static/theme-init.js` (create) | Pre-paint theme application |
| `src/app.html` (modify) | Loads `theme-init.js`; drops hardcoded light |
| `backend/lib/valea_web.ex` (modify) | Allowlists `theme-init.js` |
| `src/routes/layout.css` (modify) | `.dark` token block; dynamic `color-scheme` |
| `src/lib/components/settings/sections/AppearanceSection.svelte` (create) | The theme picker |
| `src/lib/components/mail/mail-document-palette.ts` (create) | The white-sheet values, shared by both mail branches |

---

## Stage A — Role tokens (light-mode no-op)

### Task 1: Contrast maths and token parsing

**Files:**
- Create: `src/lib/design/contrast.ts`
- Create: `src/lib/design/tokens.ts`
- Test: `src/lib/design/contrast.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `relativeLuminance(hex: string): number`
  - `contrastRatio(a: string, b: string): number`
  - `readPalette(palette: 'light' | 'dark'): Record<string, string>` — token name **without** the leading `--` → 6-digit lowercase hex. Returns `{}` for `'dark'` until Task 11 adds the block.

- [ ] **Step 1: Write the failing test**

Create `src/lib/design/contrast.test.ts`:

```ts
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

  it('reproduces the design system\'s documented light floor', () => {
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/lib/design/contrast.test.ts`
Expected: FAIL — `Failed to resolve import "./contrast"`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/design/contrast.ts`:

```ts
/**
 * WCAG relative luminance and contrast ratio, for asserting palette
 * invariants in tests. Deliberately dependency-free and pure: the palette
 * tests are the only consumer, and they must not need a DOM.
 */

function channels(hex: string): [number, number, number] {
  let h = hex.trim().replace(/^#/, '').toLowerCase();
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
  if (!/^[0-9a-f]{6}$/.test(h)) throw new Error(`not a hex colour: ${hex}`);
  return [
    parseInt(h.slice(0, 2), 16) / 255,
    parseInt(h.slice(2, 4), 16) / 255,
    parseInt(h.slice(4, 6), 16) / 255
  ];
}

function linearise(c: number): number {
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

export function relativeLuminance(hex: string): number {
  const [r, g, b] = channels(hex).map(linearise);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(a: string, b: string): number {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  const [hi, lo] = la > lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}
```

Create `src/lib/design/tokens.ts`:

```ts
/**
 * Reads the raw colour tokens straight out of `layout.css` so palette tests
 * fail when the PALETTE changes, not when a duplicated copy of it drifts.
 *
 * Only literal hex values are returned. Tokens defined as `var(...)`
 * indirections (the shadcn semantic mapping) are skipped: what the
 * invariants are about is the raw paper/ink/consequence ramps.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const CSS_PATH = fileURLToPath(new URL('../../routes/layout.css', import.meta.url));

export type Palette = 'light' | 'dark';

/**
 * `:root { ... }` holds the light palette; `.dark { ... }` holds dark.
 * Returns `{}` when the requested block does not exist yet.
 */
export function readPalette(palette: Palette): Record<string, string> {
  const css = readFileSync(CSS_PATH, 'utf8');
  const selector = palette === 'light' ? ':root' : '.dark';
  const start = css.indexOf(`${selector} {`);
  if (start === -1) return {};

  // Walk braces from the selector so nested blocks cannot end it early.
  let depth = 0;
  let end = start;
  for (let i = css.indexOf('{', start); i < css.length; i++) {
    if (css[i] === '{') depth++;
    else if (css[i] === '}' && --depth === 0) {
      end = i;
      break;
    }
  }

  const body = css.slice(start, end);
  const out: Record<string, string> = {};
  for (const [, name, value] of body.matchAll(/--([a-z0-9-]+):\s*(#[0-9a-fA-F]{3,8})\s*;/g)) {
    out[name] = value.toLowerCase();
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/lib/design/contrast.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/design/
git commit -m "feat(design): contrast maths and layout.css token parsing

Reads the palette out of layout.css rather than duplicating it, so the
invariants in the next task fail when the palette changes."
```

---

### Task 2: Pin the palette invariants (this test fails on real defects)

**Files:**
- Modify: `src/lib/design/contrast.test.ts`

**Interfaces:**
- Consumes: `contrastRatio`, `readPalette` from Task 1.
- Produces: the failing assertions Task 3 and Task 4 fix.

This task deliberately ends **red**. Two avatar fills fail in light mode today — `AccountSwitcher.svelte:38` claims "every fill carries the white initial at contrast" and that has never been true. The test encodes the claim; Task 4 makes it true.

- [ ] **Step 1: Add the invariant tests**

Append to `src/lib/design/contrast.test.ts`:

Written as `describe.each` over a one-element list on purpose: Task 10 turns
dark on by adding one word to the array, and `palette` is already in scope for
the assertions that depend on which theme is being checked.

```ts
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
```

Add `relativeLuminance` to the existing import from `./contrast` if it is not already there.

- [ ] **Step 2: Run to confirm the expected failure**

Run: `npx vitest run src/lib/design/contrast.test.ts`
Expected: FAIL on `every avatar fill carries the initial at 4.5:1` — `avatar-fill-1 must be defined` (the tokens do not exist yet). The other three invariants PASS, confirming today's ink ramp and elevation chain are sound.

- [ ] **Step 3: Commit the red test**

```bash
git add src/lib/design/contrast.test.ts
git commit -m "test(design): pin the palette invariants, including one that fails

The avatar-fill assertion encodes what AccountSwitcher.svelte:38 claims in
a comment and has never been true: measured against #fffefa at 11px
semibold, --warn-dot is 3.44:1 and --suggest-dash 2.38:1. Fixed next."
```

---

### Task 3: Move on-accent foregrounds to `--primary-foreground`

**Files:**
- Modify: `src/lib/components/shell/UpdateNotice.svelte:38`
- Modify: `src/lib/components/tasks/TaskEditor.svelte:105`
- Modify: `src/lib/components/tasks/TaskRow.svelte:83`
- Modify: `src/lib/components/agent/Composer.svelte:291`
- Modify: `src/lib/components/agent/MessageItem.svelte:34`
- Modify: `src/lib/components/shell/Logo.svelte:14,21,26`
- Modify: `src/lib/editor/tiptap.css:39`

**Interfaces:**
- Consumes: `--primary-foreground`, already defined at `layout.css:62` and exposed as `text-primary-foreground` by `@theme inline`.
- Produces: no new symbols. Every on-accent foreground now names its role.

**This is a no-op in light mode.** `--primary-foreground` and `--paper-card` are both `#fffefa`, so rendering is byte-identical. That is what makes it safe to ship separately.

- [ ] **Step 1: Replace `text-paper-card` on accent fills**

In `UpdateNotice.svelte:38`, `TaskEditor.svelte:105` and `TaskRow.svelte:83`, change `text-paper-card` → `text-primary-foreground`. Leave every *other* `bg-paper-card` in those files alone — only the foreground on a filled control changes. For example, `TaskRow.svelte:83` becomes:

```svelte
done ? 'bg-act text-primary-foreground border-transparent' : 'bg-paper-card group-hover/check:border-ink-meta',
```

- [ ] **Step 2: Replace the two `text-white` spellings**

`Composer.svelte:291` and `MessageItem.svelte:34` express the same role as a literal. Change `text-white` → `text-primary-foreground` in both. These are not broken today; they are unified so the role has one spelling and the next person cannot pick the wrong one.

Do **not** touch `WindowControls.svelte:228` — its `hover:text-white` sits on the Windows close red, a platform convention rather than a Valea token.

- [ ] **Step 3: Fix the Logo's sprig — all three lines**

In `Logo.svelte`, change `var(--paper-card)` → `var(--primary-foreground)` at **line 14** (the stem `stroke`), **line 21** and **line 26** (the leaf `fill`s). Missing line 14 leaves the stem changing colour in dark mode while the leaves do not.

- [ ] **Step 4: Point tiptap's on-accent token at the role**

In `tiptap.css:39`:

```css
    --ttp-primary-text: var(--primary-foreground);
```

Update the doc comment at `tiptap.css:18` to match — it already says "matches `--primary-foreground`", which now becomes literally true rather than aspirational.

- [ ] **Step 5: Verify nothing changed visually and nothing was missed**

Run:
```bash
grep -rn "text-paper-card\|text-white" src/lib src/routes --include="*.svelte"
```
Expected: exactly **three** hits, all of them known and correct at this point —
`WindowControls.svelte:228` (the Windows close red, which stays), and
`AccountSwitcher.svelte:62` and `:96`, whose avatar initials are rewritten in
Task 4 along with the fills underneath them. Any *other* hit is a site you
missed. Do not touch the AccountSwitcher lines here: Task 4 replaces those whole
class attributes, and changing the foreground before the fill is fixed would
make those avatars worse, not better.

Run: `npx vitest run && npm run check`
Expected: all tests pass (the avatar test still fails — that is Task 4); check reports 0 errors.

- [ ] **Step 6: Commit**

```bash
git add src/lib/components src/lib/editor/tiptap.css
git commit -m "refactor(design): name the on-accent foreground role

--paper-card is a SURFACE token being used as the ink on a consequence
fill in 5 places, and 2 more spell the same role as literal text-white.
In light mode the lightest paper is the right ink for a green button so
nobody noticed; once a second palette exists they diverge. All 7 now use
--primary-foreground, which already exists for exactly this.

Byte-identical in light mode: --primary-foreground and --paper-card are
both #fffefa."
```

---

### Task 4: Give the avatars their own fill tokens

**Files:**
- Modify: `src/routes/layout.css` (raw token block + `@theme inline`)
- Create: `src/lib/components/mail/avatar-fills.ts`
- Modify: `src/lib/components/mail/AccountSwitcher.svelte:36-44,62,96`

**Interfaces:**
- Consumes: `accountColorIndex(slug, paletteSize)` from `mail-shapes.ts:69`.
- Produces: `AVATAR_FILLS: readonly string[]` (Tailwind class names) and `avatarFillFor(slug: string): string` from `avatar-fills.ts`.

Three of the four current fills are role mistakes: `--warn-dot` is a *dot* colour, `--suggest-dash` a *dashed-border* colour, `--ink-secondary` is *ink*. None was sized to carry text, and two fail contrast today.

- [ ] **Step 1: Add the tokens**

In `src/routes/layout.css`, after the `--warn-checkbox` line inside `:root`:

```css
  /* avatar fills — four distinguishable identity colours that each carry
     `--primary-foreground` at >= 4.5:1. Deliberately NOT the consequence
     palette: an avatar means "which account", not "safe/suggests/warns",
     and the tokens it used to borrow (--warn-dot, --suggest-dash,
     --ink-secondary) are a dot, a dash and an ink — none sized to carry
     text, and two of them measured below 3.5:1 under the white initial. */
  --avatar-fill-1: #2f5d48;
  --avatar-fill-2: #8a4a2f;
  --avatar-fill-3: #6b4b8a;
  --avatar-fill-4: #2f5470;
```

And in the `@theme inline` block, beside the other colour re-exports:

```css
  --color-avatar-fill-1: var(--avatar-fill-1);
  --color-avatar-fill-2: var(--avatar-fill-2);
  --color-avatar-fill-3: var(--avatar-fill-3);
  --color-avatar-fill-4: var(--avatar-fill-4);
```

- [ ] **Step 2: Run the invariant test**

Run: `npx vitest run src/lib/design/contrast.test.ts`
Expected: PASS — all four fills now clear 4.5:1 against `#fffefa`. If any fails, darken that hex until it passes; the test is the authority, not the hex you first thought of.

- [ ] **Step 3: Extract the palette to a module**

Create `src/lib/components/mail/avatar-fills.ts`:

```ts
/**
 * Which colour an account's avatar wears. Keyed on the account slug so one
 * account looks the same everywhere (`accountColorIndex`).
 *
 * These are dedicated `--avatar-fill-*` tokens rather than borrowed
 * consequence colours. `contrast.test.ts` pins the invariant this palette
 * exists to keep: every fill carries `--primary-foreground` at >= 4.5:1, in
 * every theme. Adding a fifth colour means adding a fifth token and letting
 * that test tell you whether it is dark enough.
 */
import { accountColorIndex } from './mail-shapes';

export const AVATAR_FILLS = [
  'bg-avatar-fill-1',
  'bg-avatar-fill-2',
  'bg-avatar-fill-3',
  'bg-avatar-fill-4'
] as const;

export function avatarFillFor(slug: string): string {
  return AVATAR_FILLS[accountColorIndex(slug, AVATAR_FILLS.length)];
}
```

- [ ] **Step 4: Use it in `AccountSwitcher`**

Delete the local `AVATAR_FILLS` const (line 38), its comment (lines 35-37) and the local `avatarFill` function (lines 43-45). Import instead:

```ts
  import { avatarFillFor } from './avatar-fills';
```

Replace both call sites — line 62 and line 96 — changing `{avatarFill(selected)}`/`{avatarFill(account)}` to `{avatarFillFor(selected.account)}`/`{avatarFillFor(account.account)}`, and `text-paper-card` to `text-primary-foreground`. Line 62 becomes:

```svelte
          class="{avatarFillFor(selected.account)} text-primary-foreground flex size-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold"
```

Check the shape of `account` at line 96 — if the loop variable is already a `MailAccountStatus`, pass `account.account`; the old `avatarFill` took `Pick<MailAccountStatus, 'account'>` and read `.account`, so the slug is the same value either way.

- [ ] **Step 5: Verify**

Run: `npx vitest run && npm run check`
Expected: all pass, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add src/routes/layout.css src/lib/components/mail/
git commit -m "fix(mail): give account avatars fills that carry their initial

AccountSwitcher.svelte:38 claimed 'every fill carries the white initial at
contrast'. Measured against #fffefa at 11px semibold, --warn-dot was
3.44:1 and --suggest-dash 2.38:1 — the claim has never been true, before
dark mode is involved at all.

Three of the four were role mistakes: a dot colour, a dashed-border colour
and an ink, used as surfaces. Replaced with dedicated --avatar-fill-*
tokens; contrast.test.ts now enforces the comment's claim."
```

---

## Stage B — The settings shell

### Task 5: The section registry

**Files:**
- Create: `src/lib/components/settings/settings-sections.ts`
- Test: `src/lib/components/settings/settings-sections.test.ts`

**Interfaces:**
- Produces:
  - `type SettingsSectionId = 'agent' | 'appearance'`
  - `type SettingsSection = { id: SettingsSectionId; label: string; icon: NavIcon }`
  - `SETTINGS_SECTIONS: readonly SettingsSection[]`
  - `DEFAULT_SECTION: SettingsSectionId`

- [ ] **Step 1: Write the failing test**

Create `src/lib/components/settings/settings-sections.test.ts`:

```ts
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/lib/components/settings/settings-sections.test.ts`
Expected: FAIL — cannot resolve `./settings-sections`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/components/settings/settings-sections.ts`:

```ts
/**
 * The Settings dialog's panes, as data.
 *
 * Adding a setting is an entry here plus a component in `sections/` — the
 * modal does not grow a branch per pane. The registry deliberately holds
 * identity and labels only, not component references: the component lookup
 * lives in `SettingsModal.svelte` where the imports already are, and what
 * is worth asserting on in a test is the ORDER and the ids.
 */
import type { NavIcon } from '$lib/shell/nav';
import Bot from '@lucide/svelte/icons/bot';
import Palette from '@lucide/svelte/icons/palette';

export type SettingsSectionId = 'agent' | 'appearance';

export type SettingsSection = {
  id: SettingsSectionId;
  label: string;
  icon: NavIcon;
};

export const SETTINGS_SECTIONS: readonly SettingsSection[] = [
  { id: 'agent', label: 'Agent', icon: Bot },
  { id: 'appearance', label: 'Appearance', icon: Palette }
];

/** Where the dialog opens. */
export const DEFAULT_SECTION: SettingsSectionId = 'agent';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/lib/components/settings/settings-sections.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/components/settings/
git commit -m "feat(settings): section registry"
```

---

### Task 6: The dialog shell and the Agent section

**Files:**
- Create: `src/lib/components/settings/SettingsNav.svelte`
- Create: `src/lib/components/settings/SettingsModal.svelte`
- Create: `src/lib/components/settings/sections/AgentSection.svelte`
- Delete: `src/lib/components/agent/HarnessSettingsModal.svelte`
- Modify: `src/lib/components/shell/Sidebar.svelte:14,101-103,113`

**Interfaces:**
- Consumes: `SETTINGS_SECTIONS`, `DEFAULT_SECTION`, `SettingsSectionId` from Task 5.
- Produces: `SettingsModal` with `open = $bindable(false)`.

This is a **move**, not a rewrite. The harness save is the consent step: `set_harness_command` persists *and approves* in one call (`backend/lib/valea/api/agents.ex:392-400`).

- [ ] **Step 1: Create the nav**

Create `src/lib/components/settings/SettingsNav.svelte`:

```svelte
<script lang="ts">
  // The dialog's own nav column. Visual grammar is `SidebarItem`'s (icon,
  // label, active fill on `--paper-nav-active`) but it cannot BE
  // `SidebarItem`: that is an `<a href>` and these select a pane without
  // navigating.
  //
  // `<nav>` + `aria-current`, deliberately not `role="tablist"`. These are
  // panes of a dialog, not tabs over one dataset, and the tablist role
  // promises arrow-key semantics we would then owe an implementation and a
  // test.
  import { SETTINGS_SECTIONS, type SettingsSectionId } from './settings-sections';

  let {
    active,
    dirty = [],
    onSelect
  }: {
    active: SettingsSectionId;
    /** Sections with unsaved edits — marked so a switch never looks like a save. */
    dirty?: SettingsSectionId[];
    onSelect: (id: SettingsSectionId) => void;
  } = $props();
</script>

<nav aria-label="Settings sections" class="bg-paper-panel border-paper-hairline flex w-44 shrink-0 flex-col gap-0.5 border-r p-2">
  {#each SETTINGS_SECTIONS as section (section.id)}
    {@const Icon = section.icon}
    <button
      type="button"
      aria-current={active === section.id ? 'page' : undefined}
      onclick={() => onSelect(section.id)}
      class={[
        'flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left text-[13.5px] transition-colors',
        active === section.id
          ? 'bg-paper-nav-active text-ink-heading font-semibold'
          : 'text-ink-secondary hover:bg-paper-pill'
      ]}
    >
      <Icon class="size-[15px] shrink-0" strokeWidth={1.5} />
      <span class="truncate">{section.label}</span>
      {#if dirty.includes(section.id)}
        <span class="bg-suggest-dash ml-auto size-1.5 shrink-0 rounded-full" title="Unsaved changes"></span>
      {/if}
    </button>
  {/each}
</nav>
```

- [ ] **Step 2: Move the harness body into `AgentSection`**

Create `src/lib/components/settings/sections/AgentSection.svelte`. Copy the **entire `<script>` block** of `agent/HarnessSettingsModal.svelte` (lines 1-93) and its markup **from `{#if loading && !config}` to the closing of the Skills block** (lines 105-160), then make exactly these changes:

1. Drop the `Dialog` and `open` prop. Replace the `$effect` at line 53:

```ts
  // Activation contract: the modal mounts a section on first selection and
  // keeps it mounted, so this loads once instead of on every `open` flip —
  // and, crucially, `commandText` survives a switch to Appearance and back.
  // Losing it silently would discard the input to a security decision.
  $effect(() => {
    savedFlash = false;
    void load();
  });
```

2. Update the imports — `DoctorPanel` and `SkillsPanel` are now two directories up:

```ts
  import DoctorPanel from '$lib/components/agent/DoctorPanel.svelte';
  import SkillsPanel from '$lib/components/agent/SkillsPanel.svelte';
```
Drop the `import * as Dialog` line.

3. Add `export const dirty` so the nav can mark unsaved state. Rename the existing `const dirty = $derived(...)` (line 38) to `commandDirty`, update its two uses (the Save button's `disabled`, and the `config?.isDefault && !dirty` branch), and export it:

```ts
  const commandDirty = $derived(config !== null && commandText.trim() !== config.command.join(' '));
  export function isDirty(): boolean {
    return commandDirty;
  }
```

4. Put the header copy **inside the section**, above the harness field — it explains this pane specifically, not Settings generally:

```svelte
<div class="flex flex-col gap-3">
  <div>
    <h2 class="font-display text-ink-heading text-[17px]">Agent</h2>
    <p class="text-ink-body text-[12.5px]">
      Valea runs your own agent as a separate program and stays the approval layer around it.
      Claude Code is the built-in harness today.
    </p>
  </div>
  <!-- ... the moved body ... -->
</div>
```

Everything else — `load`, `save`, `resetToDefault`, `parsedCommand`, the trust-model comment at lines 8-13, the explicit Save button, the Diagnostics and Skills blocks — moves **unchanged**. Do not add autosave-on-blur or save-on-close.

- [ ] **Step 3: Create the modal**

Create `src/lib/components/settings/SettingsModal.svelte`:

```svelte
<script lang="ts">
  // Settings: a nav column and a section pane. Was `HarnessSettingsModal`,
  // which was one pane with no nav.
  //
  // Sections mount lazily on first selection and then STAY mounted
  // (`shown`). That is not an optimisation — destroying `AgentSection` on a
  // switch would discard an unsaved harness command, which is the input to
  // a consent decision.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import SettingsNav from './SettingsNav.svelte';
  import AgentSection from './sections/AgentSection.svelte';
  import AppearanceSection from './sections/AppearanceSection.svelte';
  import { DEFAULT_SECTION, type SettingsSectionId } from './settings-sections';

  let { open = $bindable(false) }: { open?: boolean } = $props();

  let active = $state<SettingsSectionId>(DEFAULT_SECTION);
  let shown = $state<Set<SettingsSectionId>>(new Set([DEFAULT_SECTION]));
  let agentSection = $state<ReturnType<typeof AgentSection> | null>(null);

  $effect(() => {
    if (open) {
      active = DEFAULT_SECTION;
      shown = new Set([DEFAULT_SECTION]);
    }
  });

  function select(id: SettingsSectionId): void {
    active = id;
    if (!shown.has(id)) shown = new Set([...shown, id]);
  }

  const dirtySections = $derived<SettingsSectionId[]>(agentSection?.isDirty() ? ['agent'] : []);
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="flex h-[min(600px,85vh)] gap-0 overflow-hidden p-0 sm:max-w-3xl">
    <Dialog.Title class="sr-only">Settings</Dialog.Title>
    <Dialog.Description class="sr-only">
      Configure how Valea runs your agent and how the app looks.
    </Dialog.Description>

    <SettingsNav {active} dirty={dirtySections} onSelect={select} />

    <div class="min-w-0 flex-1 overflow-y-auto p-5">
      <div hidden={active !== 'agent'}>
        {#if shown.has('agent')}<AgentSection bind:this={agentSection} />{/if}
      </div>
      <div hidden={active !== 'appearance'}>
        {#if shown.has('appearance')}<AppearanceSection />{/if}
      </div>
    </div>
  </Dialog.Content>
</Dialog.Root>
```

Note `Dialog.Content`'s defaults are `grid gap-4 p-4` — the class list above overrides all three. The title and description are `sr-only` because each section renders its own visible heading.

- [ ] **Step 4: Stub `AppearanceSection` so this task compiles**

Create `src/lib/components/settings/sections/AppearanceSection.svelte` — filled in properly in Task 11:

```svelte
<div class="flex flex-col gap-3">
  <div>
    <h2 class="font-display text-ink-heading text-[17px]">Appearance</h2>
    <p class="text-ink-body text-[12.5px]">How Valea looks on this machine.</p>
  </div>
</div>
```

- [ ] **Step 5: Point the sidebar at it**

In `Sidebar.svelte`, change the import at line 14:

```ts
  import SettingsModal from '$lib/components/settings/SettingsModal.svelte';
```

Change lines 101-102 to `aria-label="Settings"` and `title="Settings"`, and line 113 to `<SettingsModal bind:open={settingsOpen} />`.

- [ ] **Step 6: Delete the old modal and verify**

```bash
git rm src/lib/components/agent/HarnessSettingsModal.svelte
grep -rn "HarnessSettingsModal" src/ || echo "no references left"
```

Run: `npx vitest run && npm run check`
Expected: all pass, 0 errors. A `svelte-check` error about `ReturnType<typeof AgentSection>` means the component-instance type needs to be `any` — acceptable here; annotate it and move on rather than fighting the generic.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(settings): generic Settings dialog with a section nav

HarnessSettingsModal becomes SettingsModal: a nav column plus a section
pane, with the harness config moved verbatim into sections/AgentSection.

Sections stay mounted once shown. Destroying AgentSection on a section
switch would silently discard an unsaved harness command, and that command
is the input to a consent decision (set_harness_command persists AND
approves in one call), so it is kept and the nav marks it dirty.

The trust-model copy moves INTO the Agent section rather than the generic
Settings header, because it explains that pane specifically."
```

---

### Task 7: Retire the "Agent settings" copy

**Files:**
- Modify: `src/lib/components/mail/mail-shapes.ts:701`
- Modify: `src/lib/components/views/ChatView.svelte:309,441`
- Modify: `src/routes/+page.svelte:179`
- Modify: `src/lib/components/agent/Transcript.svelte:74`
- Modify: `src/lib/components/agent/DoctorPanel.svelte:74`
- Modify: `src/lib/components/mail/mail-components.test.ts:1234`

- [ ] **Step 1: Find every site — do not trust this list**

Run: `grep -rn "Agent settings" src/`
Expected: six source sites plus test assertions. Two were missed on a first pass when the spec was written, so re-derive rather than working from the list above.

- [ ] **Step 2: Update the test first**

In `mail-components.test.ts:1234`, change the expected string to:

```ts
    ['harness_unavailable', "The assistant isn't ready — open Settings → Agent (the gear in the sidebar) and run the checks."],
```

- [ ] **Step 3: Run to verify it fails**

Run: `npx vitest run src/lib/components/mail/mail-components.test.ts`
Expected: FAIL — received still says "Agent settings".

- [ ] **Step 4: Update all six source strings**

Replace `open Agent settings (the gear in the sidebar)` with `open Settings → Agent (the gear in the sidebar)`. `+page.svelte:179` reads `(gear in the sidebar)` without "the" — unify it while you are there. `Transcript.svelte:74` and `DoctorPanel.svelte:74` phrase it differently ("open Agent settings…", "the harness in Agent settings…"); keep their sentence shape, change only the surface name to `Settings → Agent`.

- [ ] **Step 5: Verify**

Run: `grep -rn "Agent settings" src/`
Expected: no output.

Run: `npx vitest run && npm run check`
Expected: all pass, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix(copy): point users at Settings -> Agent

The surface no longer exists under the old name."
```

---

## Stage C — Dark mode

### Task 8: Theme resolution and the store

**Files:**
- Create: `src/lib/stores/theme.ts`
- Create: `src/lib/stores/theme.svelte.ts`
- Test: `src/lib/stores/theme.test.ts`
- Test: `src/lib/stores/theme.test.svelte.ts`

**Interfaces:**
- Produces:
  - From `theme.ts`: `type ThemePreference = 'light' | 'dark' | 'system'`, `type ResolvedTheme = 'light' | 'dark'`, `THEME_STORAGE_KEY = 'valea.theme'`, `DARK_CLASS = 'dark'`, `resolveTheme(pref, systemPrefersDark): ResolvedTheme`, `parsePreference(raw: unknown): ThemePreference`
  - From `theme.svelte.ts`: `class ThemeStore` with `preference: ThemePreference` (get), `resolved: ResolvedTheme` (get), `setPreference(p)`, `start(): () => void`; and `export const themeStore`

- [ ] **Step 1: Write the failing pure test**

Create `src/lib/stores/theme.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { resolveTheme, parsePreference, THEME_STORAGE_KEY } from './theme';

function installFakeLocalStorage(): void {
  const data = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (k: string) => (data.has(k) ? data.get(k)! : null),
      setItem: (k: string, v: string) => void data.set(k, v),
      removeItem: (k: string) => void data.delete(k),
      clear: () => data.clear()
    },
    configurable: true,
    writable: true
  });
}

function removeLocalStorage(): void {
  // @ts-expect-error - deliberately removing the global
  delete globalThis.localStorage;
}

describe('resolveTheme', () => {
  it('follows the OS only when the preference is system', () => {
    expect(resolveTheme('system', true)).toBe('dark');
    expect(resolveTheme('system', false)).toBe('light');
  });

  it('ignores the OS when pinned', () => {
    expect(resolveTheme('light', true)).toBe('light');
    expect(resolveTheme('dark', false)).toBe('dark');
  });
});

describe('parsePreference', () => {
  it('accepts the three valid values', () => {
    expect(parsePreference('light')).toBe('light');
    expect(parsePreference('dark')).toBe('dark');
    expect(parsePreference('system')).toBe('system');
  });

  it('falls back to system for anything else', () => {
    for (const bad of ['DARK', ' dark ', '', null, undefined, 42, {}, ['dark']]) {
      expect(parsePreference(bad)).toBe('system');
    }
  });
});

describe('storage key', () => {
  beforeEach(() => installFakeLocalStorage());
  afterEach(() => removeLocalStorage());

  it('is the key the pre-paint script also uses', () => {
    // theme-init.js hardcodes this string; theme-init.test.ts pins that they agree.
    expect(THEME_STORAGE_KEY).toBe('valea.theme');
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run src/lib/stores/theme.test.ts`
Expected: FAIL — cannot resolve `./theme`.

- [ ] **Step 3: Write `theme.ts`**

```ts
/**
 * The theme preference's vocabulary and its one rule.
 *
 * Split out of `theme.svelte.ts` deliberately: `resolveTheme` is the whole
 * decision and it is testable with no runes, no DOM and no store. The
 * pre-paint script (`static/theme-init.js`) reimplements this branch,
 * because it cannot import from the bundle without becoming
 * render-blocking; `theme-init.test.ts` pins the two together.
 */

export const THEME_STORAGE_KEY = 'valea.theme';

/** The class the pre-paint script and the store both put on `<html>`. */
export const DARK_CLASS = 'dark';

export type ThemePreference = 'light' | 'dark' | 'system';
export type ResolvedTheme = 'light' | 'dark';

export function resolveTheme(
  preference: ThemePreference,
  systemPrefersDark: boolean
): ResolvedTheme {
  if (preference === 'system') return systemPrefersDark ? 'dark' : 'light';
  return preference;
}

/**
 * Anything unrecognised is `'system'` — the same tolerance `tree-state`
 * gives corrupted JSON. A stored value is user data we did not validate on
 * the way in, and a theme is never worth throwing over.
 */
export function parsePreference(raw: unknown): ThemePreference {
  return raw === 'light' || raw === 'dark' || raw === 'system' ? raw : 'system';
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx vitest run src/lib/stores/theme.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing store test**

Create `src/lib/stores/theme.test.svelte.ts`:

```ts
// @vitest-environment - runs under the `runes` project (vite.config.ts)
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { flushSync } from 'svelte';
import { ThemeStore } from './theme.svelte';
import { THEME_STORAGE_KEY } from './theme';

let listeners: Array<(e: { matches: boolean }) => void> = [];
let prefersDark = false;

function installEnvironment(): void {
  const data = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (k: string) => (data.has(k) ? data.get(k)! : null),
      setItem: (k: string, v: string) => void data.set(k, v),
      removeItem: (k: string) => void data.delete(k),
      clear: () => data.clear()
    },
    configurable: true,
    writable: true
  });
  listeners = [];
  Object.defineProperty(globalThis, 'matchMedia', {
    value: () => ({
      get matches() {
        return prefersDark;
      },
      addEventListener: (_: string, fn: (e: { matches: boolean }) => void) => listeners.push(fn),
      removeEventListener: (_: string, fn: (e: { matches: boolean }) => void) => {
        listeners = listeners.filter((l) => l !== fn);
      }
    }),
    configurable: true,
    writable: true
  });
  const classes = new Set<string>();
  Object.defineProperty(globalThis, 'document', {
    value: {
      documentElement: {
        classList: {
          add: (c: string) => classes.add(c),
          remove: (c: string) => classes.delete(c),
          contains: (c: string) => classes.has(c)
        },
        style: { colorScheme: '' }
      }
    },
    configurable: true,
    writable: true
  });
}

function teardown(): void {
  for (const g of ['localStorage', 'matchMedia', 'document']) {
    // @ts-expect-error - deliberately removing the globals
    delete globalThis[g];
  }
}

describe('ThemeStore', () => {
  beforeEach(() => {
    prefersDark = false;
    installEnvironment();
  });
  afterEach(() => teardown());

  it('defaults to system and resolves against the OS', () => {
    prefersDark = true;
    const store = new ThemeStore();
    expect(store.preference).toBe('system');
    expect(store.resolved).toBe('dark');
  });

  it('follows an OS change while on system', () => {
    const store = new ThemeStore();
    const stop = store.start();
    expect(store.resolved).toBe('light');

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();

    expect(store.resolved).toBe('dark');
    stop();
  });

  it('ignores an OS change while pinned to light', () => {
    const store = new ThemeStore();
    const stop = store.start();
    store.setPreference('light');

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();

    expect(store.resolved).toBe('light');
    stop();
  });

  it('persists the preference and reloads it', () => {
    const store = new ThemeStore();
    store.setPreference('dark');
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark');
    expect(new ThemeStore().preference).toBe('dark');
  });

  it('applies the class and color-scheme to the document', () => {
    const store = new ThemeStore();
    const stop = store.start();

    store.setPreference('dark');
    flushSync();
    expect(document.documentElement.classList.contains('dark')).toBe(true);
    expect(document.documentElement.style.colorScheme).toBe('dark');

    store.setPreference('light');
    flushSync();
    expect(document.documentElement.classList.contains('dark')).toBe(false);
    expect(document.documentElement.style.colorScheme).toBe('light');
    stop();
  });

  it('removes its media listener on stop, and does not double-register', () => {
    const store = new ThemeStore();
    const stop = store.start();
    expect(listeners.length).toBe(1);
    store.start();
    expect(listeners.length, 'a second start must not add a listener').toBe(1);
    stop();
    expect(listeners.length).toBe(0);
  });

  it('survives storage that throws on read and on write', () => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: {
        getItem: () => {
          throw new Error('denied');
        },
        setItem: () => {
          throw new Error('denied');
        }
      },
      configurable: true,
      writable: true
    });
    const store = new ThemeStore();
    expect(store.preference).toBe('system');
    expect(() => store.setPreference('dark')).not.toThrow();
    expect(store.preference).toBe('dark');
  });

  it('works with no localStorage at all', () => {
    // @ts-expect-error - deliberately removing the global
    delete globalThis.localStorage;
    const store = new ThemeStore();
    expect(store.preference).toBe('system');
    expect(() => store.setPreference('dark')).not.toThrow();
  });
});
```

- [ ] **Step 6: Run to verify it fails**

Run: `npx vitest run --project runes`
Expected: FAIL — cannot resolve `./theme.svelte`.

- [ ] **Step 7: Write `theme.svelte.ts`**

```ts
/**
 * The theme preference: what the user chose, what that resolves to right
 * now, and getting it onto `<html>`.
 *
 * Persisted to `localStorage` under `valea.theme` with the same guarded
 * posture as `recent-pages.ts` and `tree-state.svelte.ts` — no storage (SSR,
 * tests, a locked-down WebView) means the choice is session-local, never an
 * error. Per-machine on purpose: `localStorage` is the only store readable
 * early enough for `static/theme-init.js` to beat first paint.
 *
 * `start()` is called once by the root layout. The `matchMedia` listener
 * stays attached whatever the preference, so switching back to `'system'`
 * is immediately correct rather than correct at the next OS change.
 */
import { untrack } from 'svelte';
import {
  DARK_CLASS,
  THEME_STORAGE_KEY,
  parsePreference,
  resolveTheme,
  type ResolvedTheme,
  type ThemePreference
} from './theme';

const MEDIA_QUERY = '(prefers-color-scheme: dark)';

function hasLocalStorage(): boolean {
  return typeof localStorage !== 'undefined';
}

function readStored(): ThemePreference {
  if (!hasLocalStorage()) return 'system';
  try {
    return parsePreference(localStorage.getItem(THEME_STORAGE_KEY));
  } catch {
    return 'system';
  }
}

function systemPrefersDark(): boolean {
  if (typeof matchMedia === 'undefined') return false;
  try {
    return matchMedia(MEDIA_QUERY).matches;
  } catch {
    return false;
  }
}

export class ThemeStore {
  #preference = $state<ThemePreference>(readStored());
  #systemDark = $state<boolean>(systemPrefersDark());
  #stop: (() => void) | null = null;

  get preference(): ThemePreference {
    return this.#preference;
  }

  get resolved(): ResolvedTheme {
    return resolveTheme(this.#preference, this.#systemDark);
  }

  setPreference(preference: ThemePreference): void {
    this.#preference = preference;
    this.#persist();
    this.#apply();
  }

  /**
   * Attach to the OS and paint the current answer. Returns a teardown.
   * Idempotent: calling it twice must not register a second listener, or an
   * HMR reload would leave the old one attached to a dead store.
   */
  start(): () => void {
    if (this.#stop) return this.#stop;

    this.#apply();

    if (typeof matchMedia === 'undefined') {
      this.#stop = () => {
        this.#stop = null;
      };
      return this.#stop;
    }

    const query = matchMedia(MEDIA_QUERY);
    const onChange = (event: { matches: boolean }): void => {
      this.#systemDark = event.matches;
      this.#apply();
    };
    query.addEventListener('change', onChange);

    this.#stop = () => {
      query.removeEventListener('change', onChange);
      this.#stop = null;
    };
    return this.#stop;
  }

  /**
   * Untracked (issue #4): reading `#preference`/`#systemDark` here would
   * enrol any effect that calls `setPreference` as a subscriber of the state
   * it just wrote.
   */
  #apply(): void {
    if (typeof document === 'undefined') return;
    const resolved = untrack(() => resolveTheme(this.#preference, this.#systemDark));
    const root = document.documentElement;
    if (resolved === 'dark') root.classList.add(DARK_CLASS);
    else root.classList.remove(DARK_CLASS);
    root.style.colorScheme = resolved;
  }

  #persist(): void {
    if (!hasLocalStorage()) return;
    const value = untrack(() => this.#preference);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, value);
    } catch {
      // Storage full/denied — the choice just stays session-local.
    }
  }
}

export const themeStore = new ThemeStore();
```

- [ ] **Step 8: Run to verify it passes**

Run: `npx vitest run --project runes`
Expected: PASS (8 ThemeStore tests plus the existing tree-state ones).

- [ ] **Step 9: Commit**

```bash
git add src/lib/stores/theme.ts src/lib/stores/theme.svelte.ts src/lib/stores/theme.test.ts src/lib/stores/theme.test.svelte.ts
git commit -m "feat(theme): preference store with system following

resolveTheme is a pure function in a plain .ts so the rule that matters is
testable without runes or a DOM. Guarded storage throughout; start() is
idempotent so HMR cannot leave a listener attached to a dead store."
```

---

### Task 9: The pre-paint script and its delivery

**Files:**
- Create: `static/theme-init.js`
- Test: `src/lib/stores/theme-init.test.ts`
- Modify: `src/app.html`
- Modify: `backend/lib/valea_web.ex:20`

**Interfaces:**
- Consumes: `THEME_STORAGE_KEY`, `DARK_CLASS`, `resolveTheme` from Task 8 — for the *test*, not for the script.

**An inline script does not work here.** `svelte.config.js:17` sets a hash-mode CSP with `script-src 'self'`, and SvelteKit hashes only the scripts it generates. Verified: a probe inline script's hash was absent from the built CSP, so it would be blocked in production only — the flash it exists to prevent, invisible in dev.

- [ ] **Step 1: Write the failing test**

Create `src/lib/stores/theme-init.test.ts`:

```ts
/**
 * `static/theme-init.js` duplicates the storage key, the class name and the
 * resolution branch, because it cannot import from the bundle without
 * becoming render-blocking. This pins the duplication: the real file is
 * evaluated against stubbed globals and must agree with `resolveTheme` on
 * every combination.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolveTheme, THEME_STORAGE_KEY, DARK_CLASS, type ThemePreference } from './theme';

const SCRIPT = readFileSync(
  fileURLToPath(new URL('../../../static/theme-init.js', import.meta.url)),
  'utf8'
);

type RunResult = { classes: Set<string>; colorScheme: string; background: string };

function run(stored: string | null, prefersDark: boolean, opts: { throwOnRead?: boolean } = {}): RunResult {
  const classes = new Set<string>();
  const root = {
    classList: { add: (c: string) => classes.add(c), remove: (c: string) => classes.delete(c) },
    style: { colorScheme: '', background: '' }
  };
  const sandbox = {
    document: { documentElement: root },
    localStorage: {
      getItem: (k: string) => {
        if (opts.throwOnRead) throw new Error('denied');
        return k === THEME_STORAGE_KEY ? stored : null;
      }
    },
    matchMedia: () => ({ matches: prefersDark })
  };
  new Function('document', 'localStorage', 'matchMedia', SCRIPT)(
    sandbox.document,
    sandbox.localStorage,
    sandbox.matchMedia
  );
  return { classes, colorScheme: root.style.colorScheme, background: root.style.background };
}

describe('theme-init.js', () => {
  const cases: Array<[ThemePreference | null, boolean]> = [
    ['light', false], ['light', true],
    ['dark', false], ['dark', true],
    ['system', false], ['system', true]
  ];

  it.each(cases)('agrees with resolveTheme for %s / prefersDark=%s', (pref, prefersDark) => {
    const expected = resolveTheme(pref as ThemePreference, prefersDark);
    const result = run(pref, prefersDark);
    expect(result.classes.has(DARK_CLASS)).toBe(expected === 'dark');
    expect(result.colorScheme).toBe(expected);
  });

  it('treats a missing key as system', () => {
    expect(run(null, true).classes.has(DARK_CLASS)).toBe(true);
    expect(run(null, false).classes.has(DARK_CLASS)).toBe(false);
  });

  it('treats an unrecognised value as system', () => {
    expect(run('DARK', true).classes.has(DARK_CLASS)).toBe(true);
  });

  it('falls back to light when storage throws', () => {
    const result = run(null, true, { throwOnRead: true });
    expect(result.classes.has(DARK_CLASS)).toBe(false);
    expect(result.colorScheme).toBe('light');
  });

  it('sets a background so the first paint is not white', () => {
    expect(run('dark', false).background).not.toBe('');
  });
});

describe('app.html', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app.html', import.meta.url)), 'utf8');

  it('loads the script as an external file, not inline', () => {
    expect(html).toContain('theme-init.js');
    expect(html, 'an inline theme script would be CSP-blocked in production').not.toMatch(
      /<script(?![^>]*\bsrc=)[^>]*>[\s\S]*valea\.theme/
    );
  });

  it('no longer hardcodes the light theme', () => {
    expect(html).not.toContain('background:#fbf8f1');
    expect(html).not.toMatch(/name="color-scheme"\s+content="light"/);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run src/lib/stores/theme-init.test.ts`
Expected: FAIL — `ENOENT` for `static/theme-init.js`.

- [ ] **Step 3: Write the script**

Create `static/theme-init.js`:

```js
/**
 * Applies the theme before first paint.
 *
 * An EXTERNAL file, not an inline script: `svelte.config.js` sets a
 * hash-mode CSP with `script-src 'self'`, and SvelteKit hashes only the
 * scripts it generates — an inline one here is blocked in production
 * builds, which is where the launch flash would be. `'self'` allows this.
 *
 * It duplicates the key, the class and the branch from
 * `src/lib/stores/theme.ts`, because importing from the bundle would make
 * it render-blocking on the app chunk and defeat the point.
 * `theme-init.test.ts` evaluates THIS FILE and pins it to `resolveTheme`.
 *
 * Must never throw: a locked-down WebView with storage denied should get a
 * light app, not a blank one.
 */
(function () {
  var root = document.documentElement;
  var preference = 'system';

  try {
    var stored = localStorage.getItem('valea.theme');
    if (stored === 'light' || stored === 'dark' || stored === 'system') preference = stored;
  } catch (e) {
    preference = 'system';
  }

  var prefersDark = false;
  try {
    prefersDark = matchMedia('(prefers-color-scheme: dark)').matches;
  } catch (e) {
    prefersDark = false;
  }

  var resolved = preference === 'system' ? (prefersDark ? 'dark' : 'light') : preference;

  if (resolved === 'dark') root.classList.add('dark');
  else root.classList.remove('dark');

  root.style.colorScheme = resolved;
  // Covers first paint and overscroll before layout.css lands.
  root.style.background = resolved === 'dark' ? '#1e1a13' : '#fbf8f1';
})();
```

- [ ] **Step 4: Update `app.html`**

Replace the whole file:

```html
<!doctype html>
<!-- The theme is applied by `static/theme-init.js` BEFORE first paint, so
     neither the background nor `color-scheme` is hardcoded here any more.
     It is an external file rather than an inline script because the
     hash-mode CSP in svelte.config.js (`script-src 'self'`) blocks inline
     scripts it did not generate — see docs/superpowers/specs/
     2026-08-02-settings-shell-and-dark-mode-design.md. -->
<html lang="en">
	<head>
		<meta charset="utf-8" />
		<meta name="viewport" content="width=device-width, initial-scale=1" />
		<meta name="text-scale" content="scale" />
		<link rel="icon" type="image/png" href="%sveltekit.assets%/favicon.png" />
		<script src="%sveltekit.assets%/theme-init.js"></script>
		%sveltekit.head%
	</head>
	<body data-sveltekit-preload-data="hover">
		<div style="display: contents">%sveltekit.body%</div>
	</body>
</html>
```

- [ ] **Step 5: Allowlist it in Phoenix**

Without this the file 404s in production. In `backend/lib/valea_web.ex:20`:

```elixir
  def static_paths,
    do: ~w(_app assets fonts images favicon.ico favicon.png favicon.svg robots.txt theme-init.js)
```

- [ ] **Step 6: Run to verify it passes**

Run: `npx vitest run src/lib/stores/theme-init.test.ts`
Expected: PASS (10 tests).

- [ ] **Step 7: Prove delivery against a real build**

A unit test cannot check this — vitest has no build prerequisite, so reading `build/index.html` would pass vacuously on a stale artifact or fail on a clean checkout.

```bash
npx vite build
grep -o 'theme-init\.js' build/index.html
ls build/theme-init.js
```
Expected: the reference is in the built HTML and the file is emitted at the build root.

- [ ] **Step 8: Commit**

```bash
git add static/theme-init.js src/app.html src/lib/stores/theme-init.test.ts ../backend/lib/valea_web.ex
git commit -m "feat(theme): apply the theme before first paint

External file, not an inline script: svelte.config.js sets a hash-mode CSP
with script-src 'self' and SvelteKit hashes only its own inline scripts, so
a hand-written one is blocked in production builds — exactly where the
launch flash would be, and nowhere the dev server would show it.

Added to Phoenix static_paths; a root path not on that list 404s."
```

---

### Task 10: The `.dark` palette

**Files:**
- Modify: `src/routes/layout.css`
- Modify: `src/lib/design/contrast.test.ts`

- [ ] **Step 1: Extend the invariant test to both palettes**

One word. In `contrast.test.ts`, change the `describe.each` list from Task 2:

```ts
describe.each(['light', 'dark'] as const)('%s palette invariants', (palette) => {
```

Every assertion inside already reads from `p = readPalette(palette)` and already
branches on `palette` where the two themes legitimately differ, so nothing else
changes.

**`readPalette` does not follow CSS inheritance** — it reads exactly one block.
So `.dark` must redeclare *every* token these assertions touch, including any
that are deliberately identical to light (`--primary-foreground` is exactly
that case, which is why the `.dark` block above declares it). A token that is
absent comes back `undefined`, and `relativeLuminance` throws on `undefined`
before any comparison runs — so the test dies with
`TypeError: Cannot read properties of undefined (reading 'trim')` pointing into
`contrast.ts`, naming no token. Add a presence guard first, so a missing token
is reported by name instead:

```ts
  it('defines every token the invariants below read', () => {
    const required = [
      'paper-canvas', 'paper-track', 'paper-sidebar', 'paper-panel', 'paper-surface', 'paper-card',
      'paper-pill', 'paper-nav-active', 'paper-tree-active',
      'ink-heading', 'ink-body', 'ink-secondary', 'ink-subtitle', 'ink-meta', 'ink-overline',
      'primary-foreground',
      'avatar-fill-1', 'avatar-fill-2', 'avatar-fill-3', 'avatar-fill-4'
    ];
    // Non-emptiness first: an absent or differently-formatted block yields {},
    // and every per-token loop below would then pass vacuously.
    expect(Object.keys(p).length, `${palette} palette must not be empty`).toBeGreaterThan(15);
    for (const t of required) {
      expect(p[t], `${palette} must define --${t}`).toBeDefined();
    }
  });
```

Write every dark token as **6-digit** hex. `readPalette` lowercases but does not
normalise length: `#fff` comes back 3-digit, and an 8-digit `#rrggbbaa` comes
back 8-digit, which `relativeLuminance` rejects with a throw.

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run src/lib/design/contrast.test.ts`
Expected: FAIL on every `dark` case — `readPalette('dark')` returns `{}` because the block does not exist.

- [ ] **Step 3: Add the `.dark` block**

In `src/routes/layout.css`, immediately after the closing `}` of `:root` and **before** `@theme inline`:

```css
/* ── Night paper ───────────────────────────────────────────────────────────
   Dark is a warm palette, not a neutral slate: Valea is "paper & ink", and a
   grey dark mode would be a different product at night.

   Direction of lift is PRESERVED, not inverted. The elevation chain
   canvas -> sidebar -> track -> surface -> panel -> card gets lighter, so
   "lifted onto card paper" means the same thing in both themes and no
   component has to know which one it is in. `pill`, `nav-active` and
   `tree-active` sit above `card`: they are interaction-state fills, not
   elevation levels.

   `--ink-overline` is QUIETER than `--ink-meta` here, as in light. An
   earlier draft made it brighter, which measured fine but inverted the ramp
   and left the "overlines >= 700 weight only" rule with no reason behind
   it. `contrast.test.ts` pins the ordering. */
.dark {
  /* paper */
  --paper-canvas: #14120c;
  --paper-track: #17140e;
  --paper-sidebar: #1a160f;
  --paper-panel: #1c1811;
  --paper-surface: #1e1a13;
  --paper-card: #27221a;
  --paper-pill: #2c271e;
  --paper-nav-active: #322c22;
  --paper-tree-active: #37301f;
  --paper-hairline: #262119;
  --paper-border: #332e24;
  --paper-chip-border: #3d362a;
  --paper-button-border: #4a4234;
  /* ink */
  --ink-heading: #efe8d8;
  --ink-body: #d8d0be;
  --ink-secondary: #bdb4a0;
  --ink-subtitle: #a79d88;
  --ink-meta: #8a8071;
  --ink-overline: #8d7a6b;
  /* green — acts. Hover goes LIGHTER here; on dark paper, more is lighter. */
  --act: #2f7a57;
  --act-hover: #3d9269;
  --act-tint: #1c2a22;
  --act-dot: #4fa97a;
  /* amber — suggests */
  --suggest-ink: #d3ac5f;
  --suggest-dash: #a8873f;
  --suggest-tint: #2e2616;
  --suggest-bg: #26200f;
  --suggest-border: #3d3320;
  /* blue — agent at work */
  --work-dot: #6b9dc9;
  /* terracotta — warns */
  --warn-ink: #e08a5f;
  --warn-dot: #d08055;
  --warn-tint: #2e1d15;
  --warn-border: #4a2f22;
  --warn-checkbox: #5c3a29;
  /* avatar fills — lightened just enough to stay distinguishable on dark
     paper while still carrying `--primary-foreground` at >= 4.5:1. */
  --avatar-fill-1: #2f7a57;
  --avatar-fill-2: #a85c3a;
  --avatar-fill-3: #8460a8;
  --avatar-fill-4: #3a6a8f;

  /* Redeclared IDENTICALLY to `:root` on purpose. `readPalette` reads one
     block and does not follow CSS inheritance, so a token that is absent here
     comes back `undefined` and `relativeLuminance` throws on it — the
     avatar-contrast invariant would blow up in the dark run instead of
     asserting. Ink on a consequence fill stays near-white in BOTH themes;
     that is the whole point of the role token, and stating it here is what
     makes it checkable. */
  --primary-foreground: #fffefa;

  /* shadcn semantic mapping — same seam, dark values */
  --background: var(--paper-surface);
  --foreground: var(--ink-body);
  --card: var(--paper-card);
  --card-foreground: var(--ink-body);
  --popover: var(--paper-card);
  --popover-foreground: var(--ink-body);
  --primary: var(--act);
  --secondary: var(--paper-pill);
  --secondary-foreground: var(--ink-secondary);
  --muted: var(--paper-track);
  --muted-foreground: var(--ink-meta);
  --accent: var(--paper-nav-active);
  --accent-foreground: var(--ink-heading);
  --destructive: var(--warn-ink);
  --border: var(--paper-border);
  --input: var(--paper-button-border);
  --ring: var(--act);

  /* Shadows are near-invisible on dark paper — an elevation system that
     silently stops working. Deepened, and cards lean on --paper-border. */
  --shadow-card: 0 1px 2px rgba(0, 0, 0, 0.45);
  --shadow-window: 0 24px 60px rgba(0, 0, 0, 0.65);
}
```

`--primary-foreground` is deliberately **not** redefined: it stays `#fffefa` in both themes, which is the whole point of Task 3.

- [ ] **Step 4: Make `color-scheme` follow the theme**

`layout.css:149` hardcodes it inside `@layer base`. Change the `html` rule:

```css
  html {
    color-scheme: light;
    background: var(--paper-surface);
  }
  html.dark {
    color-scheme: dark;
  }
```

Also correct the file header comment at `layout.css:4-8`: the app is no longer light-only, and `@custom-variant dark (&:is(.dark *))` is now load-bearing rather than a guard against the OS media query.

- [ ] **Step 5: Run to verify it passes**

Run: `npx vitest run src/lib/design/contrast.test.ts`
Expected: PASS for both palettes. If an avatar fill fails, darken it until it passes.

Run: `npx vitest run && npm run check`
Expected: all pass, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add src/routes/layout.css src/lib/design/contrast.test.ts
git commit -m "feat(theme): the night paper palette

Warm, not neutral slate. The elevation chain keeps its direction so
'lifted onto card paper' means the same thing in both themes, and
--ink-overline stays quieter than --ink-meta so the '>= 700 weight only'
rule keeps its justification. contrast.test.ts now runs every invariant
against both palettes."
```

---

### Task 11: The Appearance section

**Files:**
- Modify: `src/lib/components/settings/sections/AppearanceSection.svelte`
- Modify: `src/routes/+layout.svelte`

**Interfaces:**
- Consumes: `themeStore` from Task 8, `SegmentedControl` (`options: {value, label}[]`, `value`, `label`, `onChange`).

- [ ] **Step 1: Start the store from the root layout**

In `src/routes/+layout.svelte`, add:

```svelte
  import { themeStore } from '$lib/stores/theme.svelte';

  // `theme-init.js` already set the class before paint; this attaches the
  // OS listener and takes ownership of later changes.
  $effect(() => themeStore.start());
```

`start()` returns its teardown, so returning it from the effect detaches the listener on destroy.

- [ ] **Step 2: Build the section**

Replace `AppearanceSection.svelte` with:

```svelte
<script lang="ts">
  // Theme choice. A mutually-exclusive set of three is a segmented control
  // by this codebase's own grammar (SegmentedControl.svelte's header).
  //
  // Per-machine, not per-workspace: it lives in localStorage because that is
  // the only store `theme-init.js` can read before first paint.
  import SegmentedControl from '$lib/components/shell/SegmentedControl.svelte';
  import { themeStore } from '$lib/stores/theme.svelte';
  import type { ThemePreference } from '$lib/stores/theme';

  const OPTIONS = [
    { value: 'light', label: 'Light' },
    { value: 'dark', label: 'Dark' },
    { value: 'system', label: 'System' }
  ];
</script>

<div class="flex flex-col gap-3">
  <div>
    <h2 class="font-display text-ink-heading text-[17px]">Appearance</h2>
    <p class="text-ink-body text-[12.5px]">How Valea looks on this machine.</p>
  </div>

  <div class="flex flex-col gap-2">
    <p class="text-overline">Theme</p>
    <SegmentedControl
      options={OPTIONS}
      value={themeStore.preference}
      label="Theme"
      onChange={(value) => themeStore.setPreference(value as ThemePreference)}
    />
    <p class="text-ink-meta text-[12px]">
      {#if themeStore.preference === 'system'}
        Following your operating system, which is currently {themeStore.resolved}.
      {:else}
        Always {themeStore.preference}, whatever your operating system does.
      {/if}
    </p>
  </div>
</div>
```

- [ ] **Step 3: Verify in the browser**

Start the dev servers with `preview_start` (`backend-dev`, then `frontend-dev`) — never `npm run dev` in a shell. Open Settings from the sidebar gear, switch to Appearance, and click through all three options. Confirm the app repaints immediately, that the dialog itself repaints, and that the choice survives a reload.

- [ ] **Step 4: Commit**

```bash
git add src/lib/components/settings/sections/AppearanceSection.svelte src/routes/+layout.svelte
git commit -m "feat(settings): the Appearance section"
```

---

### Task 12: The surfaces tokens do not reach

**Files:**
- Create: `src/lib/components/mail/mail-document-palette.ts`
- Modify: `src/lib/components/mail/HtmlMailView.svelte:45-55,94`
- Modify: `src/lib/components/mail/MessageView.svelte:852-866`
- Modify: `src/lib/components/ui/dialog/dialog-overlay.svelte:15`
- Modify: `src/lib/components/onboarding/Onboarding.svelte:30`
- Test: `src/lib/components/mail/mail-document-palette.test.ts`

**Interfaces:**
- Produces: `MAIL_DOCUMENT_PALETTE` — `{ background, ink, link, linkUnderline, chipBorder, chipBackground, chipInk }`, all literal hex.

The mail iframe is a **separate document** and cannot read app CSS variables — `HtmlMailView.svelte:42-44` already says so. So the two branches are single-sourced in TypeScript, not CSS.

- [ ] **Step 1: Write the failing test**

Create `src/lib/components/mail/mail-document-palette.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { MAIL_DOCUMENT_PALETTE } from './mail-document-palette';
import { contrastRatio } from '$lib/design/contrast';

describe('MAIL_DOCUMENT_PALETTE', () => {
  it('is a light sheet regardless of app theme', () => {
    expect(MAIL_DOCUMENT_PALETTE.background).toBe('#ffffff');
  });

  it('every ink on the sheet is readable', () => {
    for (const ink of [MAIL_DOCUMENT_PALETTE.ink, MAIL_DOCUMENT_PALETTE.link]) {
      expect(contrastRatio(ink, MAIL_DOCUMENT_PALETTE.background)).toBeGreaterThanOrEqual(4.5);
    }
  });

  it('is all literal hex — the iframe cannot resolve var()', () => {
    for (const value of Object.values(MAIL_DOCUMENT_PALETTE)) {
      expect(value).toMatch(/^#[0-9a-f]{6}$/);
    }
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run src/lib/components/mail/mail-document-palette.test.ts`
Expected: FAIL — cannot resolve `./mail-document-palette`.

- [ ] **Step 3: Write the module**

```ts
/**
 * The white sheet a mail message is rendered on, in both branches.
 *
 * Email HTML assumes a white background — dark inline text on a dark canvas
 * is invisible, and rewriting sender styles to fix it breaks inline styles,
 * background images and logos unpredictably. So the message stays a white
 * sheet of paper inside a dark app, which is coherent in a paper & ink
 * system rather than accidental.
 *
 * These are LITERALS, not `var(--…)`, and they are shared through TypeScript
 * rather than CSS: `HtmlMailView` renders into an iframe, a separate
 * document that "can't reach the app's CSS variables" (its own comment) and
 * whose CSP allows no external stylesheet. The plain-text branch feeds these
 * same values to scoped custom properties, so
 * `MessageView.svelte:852`'s promise — "the same white reading card the HTML
 * view's iframe provides" — is enforced by one definition instead of two
 * that happen to match today.
 */
export const MAIL_DOCUMENT_PALETTE = {
  background: '#ffffff',
  ink: '#1c1c1c',
  link: '#1a4d8f',
  linkUnderline: '#9db8d6',
  chipBorder: '#d8cfb9',
  chipBackground: '#fbf8f1',
  chipInk: '#948a75'
} as const;
```

- [ ] **Step 4: Use it in the iframe**

In `HtmlMailView.svelte`, import it and replace the literals in `srcdoc` (lines 49-53):

```ts
  import { MAIL_DOCUMENT_PALETTE as DOC } from './mail-document-palette';
```

```ts
      `html{background:${DOC.background}}` +
      `body{margin:12px;font:14px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:${DOC.ink};word-break:break-word}` +
      `img{max-width:100%;height:auto}` +
      `.valea-img-unavailable{display:inline-flex;align-items:center;gap:6px;padding:5px 10px;` +
      `border:1.5px dashed ${DOC.chipBorder};border-radius:8px;background:${DOC.chipBackground};color:${DOC.chipInk};font-size:12.5px;line-height:1.4}` +
```

Update the comment at lines 42-44 to point at the module. At line 94 change `bg-white` to an inline `style={`background:${DOC.background}`}` so both branches take their background from the same constant.

- [ ] **Step 5: Pin the plain-text sheet**

In `MessageView.svelte`, import the palette and replace the card (line 857) and its link (line 865). The paragraph and anchor must **not** inherit app ink, or the link resolves `--ink-heading` — near-white in dark, invisible on white:

```svelte
    <div
      class="border-paper-border rounded-xl border px-5 py-4"
      style="background:{DOC.background}; color:{DOC.ink}"
    >
      <p class="max-w-[620px] text-[14px] leading-[1.65] whitespace-pre-wrap"
      >{#each bodySegments as segment, i (i)}{#if segment.href}{@const href = segment.href}<a
            {href}
            target="_blank"
            rel="noopener noreferrer"
            onclick={(event) => onLinkClick(event, href)}
            style="color:{DOC.link}; text-decoration-color:{DOC.linkUnderline}"
            class="underline underline-offset-2"
          >{segment.text}</a>{:else}{segment.text}{/if}{/each}</p>
    </div>
```

Note the removed `text-ink-body` and `text-ink-heading` — both would follow the app theme onto a sheet that does not. Update the comment at line 852 to say the shared surface is now enforced by `mail-document-palette.ts`.

- [ ] **Step 6: Deepen the dialog overlay**

`dialog-overlay.svelte:15` is `bg-black/10`. Ten percent black over cream reads as a dim; over dark paper it is nearly invisible, so modals lose their separation — including Settings. Change `bg-black/10` to `bg-black/10 dark:bg-black/50`.

- [ ] **Step 7: Tokenize the onboarding glow**

`Onboarding.svelte:30` hardcodes `drop-shadow-[0_10px_24px_rgba(47,93,72,0.28)]` — a green glow tuned for cream. Change to `drop-shadow-[0_10px_24px_var(--act-tint)]`, which follows the theme.

- [ ] **Step 8: Verify**

Run: `npx vitest run && npm run check`
Expected: all pass, 0 errors.

- [ ] **Step 9: Commit**

```bash
git add src/lib/components/mail src/lib/components/ui/dialog/dialog-overlay.svelte src/lib/components/onboarding/Onboarding.svelte
git commit -m "fix(mail,ui): pin the white sheet and fix chrome that ignored tokens

MessageView's plain-text branch used bg-paper-card while its own comment
promised 'the same white reading card the HTML view's iframe provides' —
under a second palette the two views of one message diverged. Its link was
worse: text-ink-heading is near-white in dark, invisible on the sheet.

Single-sourced in TypeScript rather than CSS, because the iframe is a
separate document that cannot read app variables.

Also: the dialog overlay was bg-black/10, invisible on dark paper; the
onboarding glow hardcoded a cream-tuned green."
```

---

### Task 13: The shadcn `dark:` utilities that just woke up

**Files:**
- Modify: `src/lib/components/ui/input/input.svelte`
- Modify: `src/lib/components/ui/button/button.svelte`
- Modify: `src/lib/components/ui/badge/badge.svelte`
- Modify: `src/lib/components/ui/dropdown-menu/dropdown-menu-item.svelte`

22 `dark:` utilities live in these four files and **have never applied**, because `.dark` was never set. They were authored for shadcn's neutral-slate defaults, not warm night paper. This is dead code becoming live code, and no test covers it.

- [ ] **Step 1: List them**

Run: `grep -rno "dark:[a-zA-Z0-9/[-]*" src/lib/components/ui`

- [ ] **Step 2: Look at each in the browser, in dark mode**

With the dev servers running and the theme set to Dark, exercise every affected control: a text input (Settings → Agent's harness field), buttons in each variant, a badge, and an open dropdown menu with a destructive item. Compare against the same controls in Light.

- [ ] **Step 3: Retune or remove what fights the palette**

The likely offenders are `dark:bg-input/30` and `dark:bg-input/80` on `input.svelte` and `dark:bg-input/30` on the button's `outline` variant: `--input` maps to `--paper-button-border`, so these paint a control-border colour as a fill. If a utility makes a control muddier than its light counterpart, delete it — the tokens already carry the theme. Keep any that genuinely improve dark rendering.

Leave `dark:aria-invalid:*` alone; those adjust the invalid ring and are palette-agnostic.

- [ ] **Step 4: Verify and commit**

Run: `npx vitest run && npm run check`

```bash
git add src/lib/components/ui
git commit -m "fix(ui): retune shadcn dark: utilities for night paper

22 dark: utilities across four components had never applied, because .dark
was never set. Turning it on activated styling authored for shadcn's
neutral-slate defaults on a warm paper palette."
```

---

### Task 14: Verify every surface, then document

**Files:**
- Modify: `docs/DESIGN_SYSTEM.md:56,289` and §2
- Modify: `docs/testing/browser-test-plan.md:61`

- [ ] **Step 1: Walk every main surface in both themes**

With the dev servers running, visit each of Today, Chat, Mail, Calendar, Files/Knowledge, Tasks, Sources, Audit, Onboarding and the Settings dialog, in Light and then Dark.

Default views are not sufficient — contrast failures hide in **states**. On each surface exercise: hover, the selected/active row, active nav, the `refusable` hatch (`layout.css:199`), disabled buttons, and empty states.

- [ ] **Step 2: Check the surfaces this plan flagged as not automatic**

- The same message as HTML and as plain text — both must be a white sheet, and the plain-text links must be readable on it
- A PDF (`PdfView`) — the page stays white; the framing around it should be dark
- A transparent PNG (`ImageView`) — it sits on `--paper-card`; a dark-on-transparent icon will still be hard to see, which is accepted, not a bug to fix by recolouring
- The Tiptap bubble menu with an active button (`--ttp-primary-text` on `--ttp-primary`)
- A dropdown, a popover and the calendar event popover — they use Tailwind's `shadow-md`/`shadow-lg`, not `--shadow-card`, so confirm `ring-1 ring-foreground/10` separates them adequately
- The Logo in the sidebar — the sprig must look identical in both themes
- Account avatars in `AccountSwitcher` — every initial legible

Fix anything that fails, then re-run `npx vitest run && npm run check`.

- [ ] **Step 3: Confirm no launch flash, against a real build**

```bash
npx vite build
```
Serve the build through the backend and cold-load it with the preference set to Dark. Expected: no cream flash. This cannot be seen on the dev server, which is why it is checked here.

- [ ] **Step 4: Update the design system**

In `docs/DESIGN_SYSTEM.md`:

1. Replace line 289 (`- Light only; dark mode deferred (unchanged decision).`) with:

```markdown
- Light and dark. Dark is "night paper" — warm, not neutral slate — and lives
  in the `.dark` block in `layout.css`. The elevation chain keeps its
  direction in both themes; `--ink-overline` stays quieter than `--ink-meta`
  in both. `frontend/src/lib/design/contrast.test.ts` enforces both, plus the
  contrast floor below, against both palettes.
```

2. Under §2, add the dark tables from the spec (paper, ink, consequence, avatar fills).

3. Extend the contrast floor note at line 56 with the dark rule: `--ink-meta` on `--paper-surface` is the floor for meaningful text in dark and measures 4.46:1, better than light's 3.22:1; `--ink-overline` stays restricted to ≥700-weight overlines and counts.

4. Add the rule that made all of this affordable, and the one that nearly broke it:

```markdown
- **Colour reaches components through tokens, never literals — and a token is
  chosen for its ROLE, not its appearance.** Ink on a consequence fill is
  `--primary-foreground`, never `--paper-card`: in light they are the same
  value, so the mistake is invisible until a second palette exists. Surfaces
  are `--paper-*`, ink is `--ink-*`, and neither substitutes for the other.
```

In `docs/testing/browser-test-plan.md:61`, drop the "(if present)" from B4 — it is present.

- [ ] **Step 5: Commit**

```bash
git add ../docs
git commit -m "docs: dark mode is shipped; record the role-token rule

DESIGN_SYSTEM.md's 'light only; dark mode deferred' is retired, and §2
gains the rule the dark pass turned up: a token is chosen for its role, not
its appearance. --paper-card as ink-on-accent read correctly in light for
exactly as long as there was only one palette."
```

---

## Self-Review

**Spec coverage.** Settings shell → Tasks 5-7. Theme store and pre-paint → Tasks 8-9. Palette, `color-scheme`, shadows → Task 10. Appearance section → Task 11. Role tokens → Tasks 1-4. Original-document surfaces, overlay, onboarding → Task 12. Dead `dark:` utilities → Task 13. Browser verification and docs → Task 14.

**Deliberately deferred, with reasons stated in the spec:**
- The resolved-absolute-path consent disclosure (`2026-07-10-agent-slice-design.md:229-233`) is a pre-existing gap needing a backend change; it is not created or worsened here.
- The native Tauri window background is checked in Task 14 Step 3. If it flashes, the fix is `tauri.conf.json`, which is a one-line follow-up rather than a task with a test.
- Windows and Linux cold launch need hardware not available here; they remain manual checks.
- Favicon and app icons do not theme, by decision.

**Type consistency.** `resolveTheme`, `parsePreference`, `THEME_STORAGE_KEY`, `DARK_CLASS` are defined in Task 8 and consumed by Task 9's test with the same names. `ThemeStore.setPreference`/`.preference`/`.resolved`/`.start` are used identically in Tasks 8 and 11. `SETTINGS_SECTIONS`/`DEFAULT_SECTION`/`SettingsSectionId` are defined in Task 5 and consumed in Task 6. `contrastRatio`/`relativeLuminance`/`readPalette` are defined in Task 1 and consumed in Tasks 2, 10 and 12. `AVATAR_FILLS`/`avatarFillFor` are defined in Task 4 and used only there. `MAIL_DOCUMENT_PALETTE` is defined in Task 12 and used in both mail components in the same task.

**Ordering.** Task 2 ends red on purpose and Task 4 makes it green — that is the TDD cycle spanning two commits, and both commit messages say so. Task 6 needs `AppearanceSection.svelte` to exist, so it stubs it and Task 11 fills it in.
