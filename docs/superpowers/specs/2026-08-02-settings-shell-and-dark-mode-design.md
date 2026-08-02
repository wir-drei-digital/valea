# Settings Shell and Dark Mode — A Place for Preferences, and a Night Paper

**Date:** 2026-08-02
**Status:** Approved (design), pending implementation plan

## Goal

Two changes that arrive together because the second needs the first as a home.

1. **The sidebar gear stops being "Agent settings" and becomes "Settings"** — a
   dialog with its own nav down the left side, agent configuration as its first
   section, and room for the sections that come after it.
2. **Valea gets a dark theme**, chosen in a new Appearance section: Light, Dark
   or System, remembered across launches, applied before first paint.

This reverses a standing documented decision. `DESIGN_SYSTEM.md:289` reads
"Light only; dark mode deferred (unchanged decision)", and `app.html` and
`layout.css` both carry comments explaining the deferral. All three are updated
here rather than left to contradict the code.

Explicitly **not** in scope: any setting other than the harness command and the
theme; per-workspace themes (the preference is per-machine); a custom or
user-authored palette; and dark-mode rewriting of sender HTML in mail (see
[Mail keeps its white sheet](#mail-keeps-its-white-sheet)).

## Background: why dark mode is cheap here

The groundwork was laid when it was deferred. `layout.css:8` already scopes
Tailwind's `dark:` variant to an explicit class:

```css
@custom-variant dark (&:is(.dark *));
```

The comment says this exists so shadcn-svelte's `dark:` utilities "can't switch
on via the OS media query" — a class nobody sets. Setting that class is now the
feature, and the hook works as originally intended rather than being worked
around.

More importantly, colour flows through tokens with unusual discipline. Every
surface and ink is a `:root` CSS variable re-exported through `@theme inline`
as a Tailwind colour. Measured across the codebase:

| Surface | Hardcoded colours |
|---|---|
| 152 `.svelte` components | 8 matches, of which 5 are inside comments |
| `src/lib/editor/tiptap.css` | 0 |
| all components, `rgba(` | 1 |

So redefining the variables under `.dark` moves nearly the whole app. The real
three exceptions are enumerated under [Special cases](#special-cases).

## Part 1 — The settings shell

### Structure

`agent/HarnessSettingsModal.svelte` becomes `settings/SettingsModal.svelte`.
Its current body moves **verbatim** into `settings/sections/AgentSection.svelte`
minus the `Dialog.*` chrome; its load/save/reset logic and trust-model comment
travel with it unchanged. This is a move, not a rewrite — the harness consent
step is security-relevant and must not be quietly re-implemented.

```
src/lib/components/settings/
  SettingsModal.svelte        dialog shell: nav column + section pane
  SettingsNav.svelte          the nav list inside the dialog
  settings-sections.ts        the registry (pure data, no Svelte)
  settings-sections.test.ts
  sections/
    AgentSection.svelte       moved from agent/HarnessSettingsModal.svelte
    AppearanceSection.svelte  new
```

### The registry is data

Sections are declared as a plain array, not a hardcoded chain of `{#if}` in the
modal:

```ts
export type SettingsSectionId = 'agent' | 'appearance';

export const SETTINGS_SECTIONS: readonly SettingsSection[] = [
  { id: 'agent', label: 'Agent', icon: Bot },
  { id: 'appearance', label: 'Appearance', icon: Palette }
];

export const DEFAULT_SECTION: SettingsSectionId = SETTINGS_SECTIONS[0].id;
```

"More settings to come later" is then one entry plus one component. The
component lookup stays in the modal (a registry holding component references is
harder to test and buys nothing); the registry holds identity and labels, which
is the part worth asserting on.

### Layout

| Property | Value | Why |
|---|---|---|
| Width | `sm:max-w-3xl` (was `sm:max-w-lg`) | Two columns need the room |
| Height | `h-[min(600px,85vh)]`, fixed | A fixed height stops the dialog resizing as you switch sections |
| Nav column | `w-44` (176px), `bg-paper-panel`, full height | Panel paper is what §11 already uses for rails |
| Section pane | `flex-1`, `overflow-y-auto` | Only the pane scrolls; the nav never leaves |

The dialog's own `overflow-y-auto` (currently on `Dialog.Content`) moves to the
section pane, otherwise the nav scrolls with the content.

Nav items reuse the existing `SidebarItem` grammar — icon, label, active fill on
`--paper-nav-active` — rather than inventing a second nav vocabulary. Selection
is `$state` inside the modal, reset to `DEFAULT_SECTION` each time it opens.

### Accessibility

The nav is a `<nav>` of `<button>`s with `aria-current="page"` on the active
one, not a `role="tablist"`. These are panes of a settings dialog, not tabs over
one dataset, and the tablist role would promise arrow-key semantics we would
then have to implement and test. Focus moves to the section heading on switch so
a screen reader announces the new pane.

### Copy that goes stale

Four places tell the user to "open Agent settings (the gear in the sidebar)".
That surface no longer exists under that name:

- `lib/components/mail/mail-shapes.ts:701`
- `lib/components/views/ChatView.svelte:309`
- `lib/components/agent/Transcript.svelte:74`
- `lib/components/agent/DoctorPanel.svelte:74`

All become "open Settings → Agent (the gear in the sidebar)".
`mail-components.test.ts:1234` asserts one of these strings verbatim and is
updated with it.

## Part 2 — The theme system

### The preference and the resolution

Three preferences, two outcomes:

```ts
type ThemePreference = 'light' | 'dark' | 'system';
type ResolvedTheme = 'light' | 'dark';

export function resolveTheme(pref: ThemePreference, systemPrefersDark: boolean): ResolvedTheme {
  if (pref === 'system') return systemPrefersDark ? 'dark' : 'light';
  return pref;
}
```

`resolveTheme` is a **pure function in a plain `.ts` file**, so the rule that
matters is testable without runes, a DOM, or a store. Default preference is
`'system'`.

### The store

`stores/theme.svelte.ts` owns preference, persistence and application:

- Persists to `localStorage` under `valea.theme`, with the same guarded-storage
  posture as `tree-state.svelte.ts` and `recent-pages.ts`: absent or throwing
  storage means the preference is session-local, never an error.
- An unrecognised stored value falls back to `'system'` rather than throwing —
  same tolerance `tree-state` gives corrupted JSON.
- Subscribes to `matchMedia('(prefers-color-scheme: dark)')` so a `'system'`
  preference follows the OS live, and keeps the listener attached regardless of
  preference so switching back to `'system'` is immediately correct.
- Applies the resolved theme by toggling `.dark` on `<html>` and setting
  `color-scheme`.

Writes go through untracked reads on the write path, per the lesson from issue
#4 — a store whose write path reads its own `$state` enrolls its callers as
subscribers.

### Applying it before first paint

`app.html` currently hardcodes the light theme in two places:

```html
<html lang="en" style="background:#fbf8f1">
<meta name="color-scheme" content="light" />
```

Without a pre-paint step, every launch on a dark preference flashes cream before
the app boots. A small inline script in `<head>` reads the same key and sets the
class, `color-scheme` and background before first paint. It must not throw when
storage is unavailable (private mode, or a WebView with storage disabled) —
failure falls back to light.

This duplicates the storage key, the class name and the resolution branch. The
duplication is deliberate: the script cannot import from the bundle without
becoming render-blocking, which defeats its purpose. It is guarded by
`app-html-theme.test.ts`, which reads `src/app.html` and asserts it still
references the storage key and class name the store exports. A drift here shows
up as a launch flash — the kind of defect that survives review because nobody
relaunches cold while reviewing.

### The palette

`.dark` redefines every colour token in `:root`. Non-colour tokens (radius,
fonts, `--window-controls-inset`) are not redefined.

**Direction of lift is preserved, not inverted.** In light, `canvas` is the
darkest paper and `card` the lightest; a lifted element is lighter than its
container. Dark keeps that relationship — `canvas` darkest, `card` lightest — so
"lifted onto card paper" continues to mean the same thing and no component needs
to reason about which theme it is in.

Starting ramp, warm (hue ≈ 40°, low saturation) so it reads as night paper
rather than neutral slate:

| Token | Light | Dark |
|---|---|---|
| `--paper-canvas` | `#e9e3d6` | `#14120c` |
| `--paper-sidebar` | `#f3eee2` | `#17140e` |
| `--paper-track` | `#eee8d9` | `#1a160f` |
| `--paper-surface` | `#fbf8f1` | `#1e1a13` |
| `--paper-panel` | `#f7f2e7` | `#221e16` |
| `--paper-card` | `#fffefa` | `#27221a` |
| `--paper-pill` | `#ece5d2` | `#2c271e` |
| `--paper-nav-active` | `#e7dfca` | `#322c22` |
| `--paper-tree-active` | `#eee5cf` | `#37301f` |
| `--paper-hairline` | `#efe9da` | `#262119` |
| `--paper-border` | `#e6decb` | `#332e24` |
| `--paper-chip-border` | `#e0d7c1` | `#3d362a` |
| `--paper-button-border` | `#d8cfb9` | `#4a4234` |
| `--ink-heading` | `#29251e` | `#efe8d8` |
| `--ink-body` | `#3d3b30` | `#d8d0be` |
| `--ink-secondary` | `#57503f` | `#bdb4a0` |
| `--ink-subtitle` | `#6e6656` | `#a79d88` |
| `--ink-meta` | `#948a75` | `#8a8071` |
| `--ink-overline` | `#a89085` | `#a08c7e` |

Consequence colours keep their meanings and gain dark-appropriate values. Note
`--act-hover` goes **lighter** than `--act` in dark, where light darkens it —
hover means "more", and on dark paper more is lighter:

| Token | Light | Dark |
|---|---|---|
| `--act` | `#2f5d48` | `#2f7a57` |
| `--act-hover` | `#244938` | `#3d9269` |
| `--act-tint` | `#e6ede2` | `#1c2a22` |
| `--act-dot` | `#2f8a5b` | `#4fa97a` |
| `--suggest-ink` | `#8f6e1f` | `#d3ac5f` |
| `--suggest-dash` | `#c9a24b` | `#a8873f` |
| `--suggest-tint` | `#f4e8d2` | `#2e2616` |
| `--suggest-bg` | `#f9f2e3` | `#26200f` |
| `--suggest-border` | `#e8d9b5` | `#3d3320` |
| `--work-dot` | `#4a7dab` | `#6b9dc9` |
| `--warn-ink` | `#b4512e` | `#e08a5f` |
| `--warn-dot` | `#c0793f` | `#d08055` |
| `--warn-tint` | `#f6e7de` | `#2e1d15` |
| `--warn-border` | `#ebd5c6` | `#4a2f22` |
| `--warn-checkbox` | `#e0bda9` | `#5c3a29` |

**These values are a starting ramp, not the finished palette.** They get tuned
against real surfaces in the browser. Two pairings are known risks and must be
checked explicitly rather than eyeballed: `--act` has to still read as *safe,
approved* at night (a green that drifts toward mint or lime stops meaning
"reversible" and starts meaning "success confetti"), and `--suggest` and
`--warn` must stay tellable apart, because the entire safety grammar — amber
suggests, terracotta warns — rests on distinguishing them at a glance.

**Contrast rule.** `DESIGN_SYSTEM.md:56` states the light floor as a token
relationship: `#948A75` is the lightest ink allowed on `#FBF8F1` for meaningful
text (≈3.22:1), and `#A89085` is for overlines ≥700 weight and decorative counts
only. Dark mirrors the rule: `--ink-meta` on `--paper-surface` is the floor for
meaningful text and **must measure at least as well as the light pairing does**;
`--ink-overline` stays restricted to ≥700-weight overlines and counts. Any
pairing below the floor is fixed, not documented as a known issue.

### Shadows

`--shadow-card` and `--shadow-window` are warm-black alpha, which is close to
invisible on dark paper — an elevation system that silently stops working.
Dark raises opacity and leans on `--paper-border` for card separation, since
borders do the work shadows cannot at low luminance.

## Special cases

Three things do not follow from tokens.

### Mail keeps its white sheet

`HtmlMailView.svelte:49` forces `html{background:#fff}` inside the sandboxed
iframe, and it stays. Real email HTML assumes a white background: dark inline
text on a dark canvas is invisible, and rewriting sender HTML to fix it breaks
inline styles, background images and logos unpredictably. Dark-mode email is
unsolved industry-wide, and a mail client that mangles messages is worse than
one that renders them brightly.

The message therefore reads as a white sheet of paper inside a dark app, which
is coherent in a Paper & ink system rather than accidental. A hairline border
around the iframe makes it read as a sheet rather than a rendering bug. The
`.valea-img-unavailable` chip inside the iframe keeps its literal light values,
since it sits on that white sheet.

### The Windows close button stays red

`WindowControls.svelte:228` hardcodes `hover:bg-[#c42b1c]`. That is the Windows
close-affordance red and it is correct on any background; it is a platform
convention, not a Valea token.

### The native window background

Tauri paints the native window before the webview has anything to show. The
`app.html` inline script cannot help there — it runs too late. Whether this
produces a visible light flash on launch in dark mode is **unverified**, and
verifying it is part of the work: launch the desktop app cold in dark mode and
look. If it flashes, the fix is the window background in `tauri.conf.json`; if
that cannot be made theme-aware without a restart, the fallback is a neutral
dark window background, which is unobtrusive under both themes.

## Testing

**Unit**

| File | Covers |
|---|---|
| `stores/theme.test.ts` | `resolveTheme` across all three preferences; persistence round trip; unrecognised and corrupt stored values; no-`localStorage` guard |
| `stores/theme.test.svelte.ts` | Following an OS change while on `'system'`; not following it while pinned to `'light'`/`'dark'`; class and `color-scheme` applied on change |
| `settings/settings-sections.test.ts` | Registry non-empty, ids unique, `DEFAULT_SECTION` is a real id |
| `app-html-theme.test.ts` | `app.html` still references the store's storage key and class name |

The runes test uses the `runes` vitest project added in the issue #4 fix
(`*.test.svelte.ts` + `vitest-env-svelte-client.ts`). `matchMedia` does not
exist in that environment and is stubbed per test.

**Browser** — every main surface at both themes: Today, Chat, Mail, Calendar,
Files/Knowledge, Tasks, Sources, Audit, and the Settings dialog itself. Checking
default views alone is not sufficient: contrast failures hide in *states* —
hover, selected, active nav, the `refusable` hatch, disabled buttons, empty
states — so those are exercised deliberately.

Also verified: no cream flash on a cold launch with a dark preference; switching
themes with the Settings dialog open repaints the dialog itself.

## Documentation

- `DESIGN_SYSTEM.md:289` — "Light only; dark mode deferred (unchanged decision)"
  is replaced by the dark palette tables and the dark contrast floor. §2 gains
  the rule that made this affordable: colour reaches components through tokens,
  never as literals.
- `app.html` and `layout.css:4-8` — comments asserting the app is light-only are
  corrected.
- `docs/testing/browser-test-plan.md:61` — B4 is "Dark mode / theme toggle (if
  present)". The parenthetical goes; it is present.

## Rejected alternatives

**Backend app config for the preference.** Considered because it fits the
file-first posture and would survive a storage clear. Rejected because it costs
an RPC round trip on boot, which forces a choice between a light flash and
holding the app blank until it resolves. Theme is a per-machine display
preference — a second monitor at a different desk can reasonably differ — and
`localStorage` is the only store readable early enough to prevent the flash.

**Inverting the light palette programmatically.** Rejected: a mechanical
inversion of a warm cream palette gives muddy brown-grey, and it inverts the
consequence colours too, which is exactly the thing that must not drift.

**`role="tablist"` for the settings nav.** Rejected: it promises arrow-key
semantics that would then need implementing and testing, for panes that are not
tabs over a shared dataset.

**Deep-linking sections via the URL (`?settings=appearance`).** Rejected as
YAGNI. The stale copy points users at the gear, not at a link. If a future
section needs addressing from outside, the registry already gives it an id.
