# Settings Shell and Dark Mode — A Place for Preferences, and a Night Paper

**Date:** 2026-08-02
**Status:** Implemented

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
[Original-document surfaces stay light](#original-document-surfaces-stay-light)).

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
| 152 `.svelte` components, hex literals | 9 total — 6 in code, 3 inside comments |
| the 6 live hex literals | 5 in the mail iframe's `srcdoc`, 1 the Windows close red |
| `src/lib/editor/tiptap.css` | no hex; one `rgba()` (`--ttp-shadow`, `tiptap.css:42`) |
| all components, `rgba(` | 1 (`Onboarding.svelte:30`) |
| SVG (`Logo`, `PlantGrowth`) | 0 literals — every `fill`/`stroke` is `var(--…)` |

So redefining the variables under `.dark` moves most of the app. It does **not**
move everything, and the gap is not only literal colours — a correctly
tokenized reference can still be the *wrong token* once the palette has two
modes. That failure mode is the subject of
[Role tokens vs surface tokens](#role-tokens-vs-surface-tokens), and it is the
single largest piece of work here. Remaining exceptions are enumerated under
[Special cases](#special-cases).

## Part 1 — The settings shell

### Structure

`agent/HarnessSettingsModal.svelte` becomes `settings/SettingsModal.svelte`.
Its current body moves into `settings/sections/AgentSection.svelte` minus the
`Dialog.*` chrome; its load/save/reset logic and trust-model comment travel with
it unchanged. This is a move, not a rewrite — the harness consent step is
security-relevant and must not be quietly re-implemented.

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

"Verbatim move" is the intent but is **not achievable mechanically**, and
pretending otherwise is how the consent step gets damaged. Two things must be
designed rather than copied:

**Activation.** `HarnessSettingsModal.svelte:53` loads config from an effect
gated on the dialog's `open` prop. `AgentSection` has no `open` prop, so it
needs an explicit contract: it loads on mount, and the modal mounts sections
lazily on first selection. Sections stay mounted once shown, which is also what
makes the next point work.

**Unsaved command text survives section switches.** If sections are destroyed on
switch, typing a harness command, clicking Appearance and returning silently
discards it. Since `commandText` is the input to a security decision, losing it
quietly is worse than an ordinary form-state bug. Keeping the section mounted
preserves it; a dirty section additionally shows its unsaved state in the nav so
the user is not left believing a command was saved.

**The consent framing is not decoration.** The dialog header at
`HarnessSettingsModal.svelte:98-102` explains that Valea runs the agent as a
separate program. That copy moves *into the Agent section*, not into the generic
Settings header, because it explains this section specifically. Saving still
happens only via the explicit button — no autosave on blur, no save-on-close —
since `set_harness_command` persists **and approves** in one call
(`backend/lib/valea/api/agents.ex:392-400`), and a generic Settings surface makes
it more important, not less, that approving an executable stays a deliberate act.

**Out of scope, stated so it is not lost:** `2026-07-10-agent-slice-design.md:229-233`
requires the UI to show the *resolved absolute path* before first use. It does
not today — `harness_config` returns the configured command, not a resolved
executable path. That is a **pre-existing** consent gap, it is not created or
worsened by this restructure, and closing it needs a backend change. It is
recorded here and left for its own change rather than smuggled into a settings
reshuffle.

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

**Six** places tell the user to "open Agent settings (the gear in the sidebar)".
That surface no longer exists under that name:

- `lib/components/mail/mail-shapes.ts:701`
- `lib/components/views/ChatView.svelte:309`
- `lib/components/views/ChatView.svelte:441`
- `routes/+page.svelte:179`
- `lib/components/agent/Transcript.svelte:74`
- `lib/components/agent/DoctorPanel.svelte:74`

All become "open Settings → Agent (the gear in the sidebar)".
`mail-components.test.ts:1234` asserts one of these strings verbatim and is
updated with it. Note `+page.svelte:179` says "(gear in the sidebar)" while the
others say "(the gear…)" — the copy is unified while it is being touched.

Implementation starts by re-running `grep -rn "Agent settings" src/` rather than
trusting this list: two of the six were missed on a first pass, and the count is
the kind of thing that drifts between spec and merge.

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

The light theme is currently hardcoded in **three** places, not two:

| Location | Declaration |
|---|---|
| `app.html:5` | `<html lang="en" style="background:#fbf8f1">` |
| `app.html:10` | `<meta name="color-scheme" content="light" />` |
| `layout.css:149` | `color-scheme: light;` inside `@layer base html` |

All three change. `layout.css:149` is easy to miss and is the one that actually
governs UA scrollbars and form controls once stylesheets load, so updating only
the meta tag would leave native chrome light in dark mode. The inline `style` on
`<html>` outranks the stylesheet, so the pre-paint step must overwrite it rather
than rely on CSS.

**The pre-paint code ships as `static/theme-init.js`, loaded with
`<script src>` — not as an inline script.** This is not a style preference; an
inline script does not run:

`svelte.config.js:17` configures a hash-mode CSP with `script-src: ['self']` and
no `'unsafe-inline'`. SvelteKit hashes the scripts *it* generates, not
hand-written ones in the `app.html` template. Verified empirically by adding a
probe inline script, running `vite build`, and hashing every inline script in
`build/index.html`:

```
inline scripts found: 2
[0] window.__valeaThemeProbe=1;   sha256-O1jL7yb/Ww1YYEY5Ki6n75jTRSNwOxnUjkdKnS2F5yQ=
[1] SvelteKit bootstrap            sha256-eYZ5xcnm13raKgZJy1HyWHtVtY1O4rFHwfps6w8a9jA=

emitted CSP: script-src 'self' 'sha256-eYZ5xcnm13raKgZJy1HyWHtVtY1O4rFHwfps6w8a9jA='
```

Only the bootstrap hash is present. The probe's hash is absent, so an inline
theme script would be **blocked** — producing exactly the cream flash it exists
to prevent, and only in a production build, where it is least likely to be
caught. (The Phoenix response header at `spa_controller.ex:35` does permit
`'unsafe-inline'`, but the browser enforces the *intersection* of header and
meta, and the meta is the stricter one. `svelte.config.js` documents this.)

A same-origin `<script src="%sveltekit.assets%/theme-init.js">` satisfies
`script-src 'self'` with no hash to maintain. It also makes the code a real
`.js` file that can be unit-tested directly, instead of a string embedded in
HTML that can only be regex-asserted.

**It must be added to Phoenix's static allowlist or it will 404.**
`backend/lib/valea_web.ex:20` serves only:

```elixir
~w(_app assets fonts images favicon.ico favicon.png favicon.svg robots.txt)
```

A root `/theme-init.js` is not on that list. (The favicon works precisely
*because* `favicon.png` is named there — so "it works like the favicon" is not
an argument, it is the thing that has to be arranged.) Either `theme-init.js`
joins `static_paths`, or the file ships under `static/assets/` so it is served
by the already-allowlisted `assets` prefix. **Decision: add it to
`static_paths`**, because an explicit name is greppable and a file under
`assets/` looks like build output while being hand-written.

This must be verified in **both** delivery paths — Phoenix serving the SPA, and
the Tauri production bundle — since a 404 here degrades exactly the way an
inline-script CSP block does: silently, and only outside the dev server.

The script stays tiny and dependency-free: read `valea.theme`, resolve against
`matchMedia`, set the class, `color-scheme` and background. It must not throw
when storage is unavailable (private mode, or a WebView with storage disabled);
failure falls back to light.

It necessarily duplicates the storage key, class name and resolution branch,
because it cannot import from the bundle without becoming render-blocking on the
app chunk. `theme-init.test.ts` guards the duplication by evaluating the real
file against a stubbed `document`/`localStorage`/`matchMedia` and asserting it
produces the same result as `resolveTheme` for all six preference × OS
combinations.

That test deliberately stops there. Whether the built page actually *references*
the file, and whether the server actually serves it, cannot be asserted by
`vitest run` — see [Testing](#testing) for why reading `build/index.html` from a
unit test is worse than not testing it. Those two facts are release-path checks.

### The palette

`.dark` redefines every colour token in `:root`. Non-colour tokens (radius,
fonts, `--window-controls-inset`) are not redefined.

**The elevation chain keeps its order.** Sorted by luminance, the light
palette's structural surfaces run `canvas` → `track` → `sidebar` → `panel` →
`surface` → `card`: the desk is darkest, a recessed control track sits above it,
then the sidebar and rail chrome, then the content surface, with a card lifted
highest. Dark reproduces **that** order, so "lifted onto card paper" means the
same thing in both themes and no component has to reason about which one it is
in.

Note the order is not the order the tokens are declared in, and getting it
wrong is easy: an earlier draft of this palette put `panel` above `surface` and
swapped `sidebar` with `track`, which is monotonic in its own ordering while
silently inverting two relationships the light palette has. The invariant is
checked against the light palette's actual ordering, not against a chain
someone wrote down.

**Interaction fills move the other way, and that is correct.** `pill`,
`nav-active` and `tree-active` are *darker* than their surface in light and
*lighter* than it in dark: to pick a row out you darken cream paper and lighten
dark paper. Their invariant is therefore "stands off its surface", never "is
lighter than" — the one place the two themes legitimately run in opposite
directions.

Starting ramp, warm (hue ≈ 40°, low saturation) so it reads as night paper
rather than neutral slate:

| Token | Light | Dark |
|---|---|---|
| `--paper-canvas` | `#e9e3d6` | `#14120c` |
| `--paper-track` | `#eee8d9` | `#17140e` |
| `--paper-sidebar` | `#f3eee2` | `#1a160f` |
| `--paper-panel` | `#f7f2e7` | `#1c1811` |
| `--paper-surface` | `#fbf8f1` | `#1e1a13` |
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
| `--ink-overline` | `#a89085` | `#8d7a6b` |

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

Measured for the ramp above, on `--paper-surface` `#1e1a13`:

| Ink | Dark | Light equivalent |
|---|---|---|
| heading | 14.19:1 | — |
| body | 11.29:1 | — |
| secondary | 8.41:1 | — |
| subtitle | 6.45:1 | — |
| meta | **4.46:1** | 3.22:1 — dark clears it |
| overline | 4.23:1 | quieter than meta, as in light |

The ordering matters as much as the numbers, and it is easy to get wrong in
dark. An earlier draft used `#a08c7e` for the dark overline, which measured
5.40:1 — *more* readable than `--ink-meta`, inverting the light ramp where
overline is the quietest ink and is restricted precisely because it is the
quietest. That would have left the "≥700 weight only" rule with no reason
behind it, and invited someone to relax it. `#8d7a6b` keeps overline below meta
in both themes, so the restriction is justified by the same fact in both.

The lift ordering is likewise verified numerically, not by eye — and against
the light palette's ordering rather than a plausible-looking one:

| Surface | Light L | Dark L |
|---|---|---|
| `canvas` | 0.7712 | 0.00608 |
| `track` | 0.8090 | 0.00714 |
| `sidebar` | 0.8570 | 0.00828 |
| `panel` | 0.8905 | 0.00941 |
| `surface` | 0.9399 | 0.01062 |
| `card` | 0.9905 | 0.01650 |

Both columns ascend, in the same order, so "lifted is lighter" holds in dark
exactly as it does in light. The three interaction fills are excluded from this
chain by design, per the note above.

### Role tokens vs surface tokens

This is the largest and least obvious piece of work, and swapping the palette
without it produces unreadable UI.

`--paper-card` is a **surface** token meaning "the lightest paper". In several
places it is used as a **role**: the ink that sits *on top of* a consequence
fill. In light mode the two coincide — the lightest paper is near-white, and
near-white is what you want on a dark green button, so nobody noticed. In dark
mode they diverge completely: `--paper-card` becomes `#27221a`, and dark ink on
a dark green fill measures roughly **3.0:1**, under the 4.5:1 normal text needs.

The role has **three different spellings** in the codebase today, which is why
the bug went unnoticed — no single grep shows it:

| Site | Spelling | Dark behaviour |
|---|---|---|
| `UpdateNotice.svelte:38` | `bg-act … text-paper-card` | breaks |
| `TaskEditor.svelte:105` | `bg-act text-paper-card` | breaks |
| `TaskRow.svelte:83` | `bg-act text-paper-card` | breaks |
| `AccountSwitcher.svelte:62`, `:96` | avatar ink, `text-paper-card` | breaks |
| `tiptap.css:39` | `--ttp-primary-text: var(--paper-card)` (used at `:535`) | breaks |
| `Composer.svelte:291` | `bg-act … text-white` | works, but bypasses tokens |
| `MessageItem.svelte:34` | `bg-act … text-white` | works, but bypasses tokens |

The codebase already has the right token — `layout.css:62` defines
`--primary-foreground: #fffefa`, and `tiptap.css:18` even documents
`--ttp-primary-text` as "matches `--primary-foreground`". The work is to make
all seven say what they mean:

- Every on-accent foreground moves to `--primary-foreground` (exposed as
  `text-primary-foreground`), which stays near-white in **both** themes because
  the consequence fills stay dark enough to carry light ink.
- `--ttp-primary-text` points at `--primary-foreground` rather than `--paper-card`.
- The two `text-white` sites move too. They are not broken, but leaving them
  means the role has two spellings and the next person picks the wrong one.

This migration ships **before** the `.dark` block, as a no-op refactor in light
mode: `--primary-foreground` and `--paper-card` are both `#fffefa`, so light
rendering is byte-identical and the change is safe to verify on its own.

### The inverse: ink tokens used as fills

The same confusion runs the other way, and one instance interacts badly with the
migration above.

`AccountSwitcher.svelte:38` defines the avatar palette as:

```ts
const AVATAR_FILLS = ['bg-act', 'bg-warn-dot', 'bg-suggest-dash', 'bg-ink-secondary'];
```

Its comment reads "the consequence palette's dark tones — every fill carries the
white initial at contrast". **That claim is already false today**, before dark
mode exists. Measured against `--primary-foreground` (`#fffefa`), with the
initials rendered at `text-[11px] font-semibold` — normal text, so the 4.5:1
threshold applies:

| Fill | Light (today) | Dark (proposed) |
|---|---|---|
| `--act` | 7.48:1 ✅ | 5.15:1 ✅ |
| `--warn-dot` | **3.44:1 ❌** | **3.02:1 ❌** |
| `--suggest-dash` | **2.38:1 ❌** | **3.36:1 ❌** |
| `--ink-secondary` | 7.93:1 ✅ | **2.04:1 ❌** |

Two of the four have never met the invariant their own comment asserts. Dark
mode does not cause this; it exposes it, and adds a fourth failure because
`--ink-secondary` inverts from `#57503f` to a light `#bdb4a0`.

The root cause is role confusion three times over. `--warn-dot` is a *dot*
colour, `--suggest-dash` is a *dashed-border* colour, and `--ink-secondary` is
*ink* — none is a surface, and none was ever sized to carry text. They were
picked because they looked right at 24px.

The fix is a dedicated set of **avatar fill tokens**, defined per theme and
contrast-checked against `--primary-foreground` as a stated requirement rather
than an assumption. The four accounts keep four visually distinct colours in the
Paper & ink family; they simply stop borrowing tokens that mean something else.
The comment is rewritten, since the palette is no longer "the consequence
palette's dark tones".

Scope note: two of these failures are pre-existing and would be equally real if
this spec were abandoned. They are fixed here rather than filed separately
because the migration touches these exact lines, and shipping a change that
leaves a measured 2.38:1 in place while claiming a contrast pass would be worse
than not measuring at all.

**Not a bug, checked and dismissed:** `IcmProjects.svelte:254` (`bg-ink-meta`)
and `TaskRow.svelte:83` (`border-ink-meta`) also use ink tokens non-textually,
but they are 4px dots and hairlines with nothing on top of them. A mark that
tracks the ink ramp stays correctly visible against paper in both themes, which
is what the ink ramp is for. They are left alone.

### Shadows

`--shadow-card` and `--shadow-window` are warm-black alpha, which is close to
invisible on dark paper — an elevation system that silently stops working.
Dark raises opacity and leans on `--paper-border` for card separation, since
borders do the work shadows cannot at low luminance.

Redefining those two tokens is **not sufficient**, because four surfaces use
Tailwind's built-in shadow scale instead and never touch them:
`dropdown-menu-content.svelte:26` (`shadow-md`), `dropdown-menu-sub-content.svelte:15`
(`shadow-lg`), `popover-content.svelte:26` (`shadow-md`) and
`EventPopover.svelte:73` (`shadow-lg`). These are floating surfaces — exactly
where elevation matters most. They keep their `ring-1 ring-foreground/10`,
which is token-based and does survive the theme switch; the dark pass verifies
that ring alone separates them adequately and adds a border if it does not.

`Onboarding.svelte:30` hardcodes `drop-shadow-[0_10px_24px_rgba(47,93,72,0.28)]`
— a green-tinted glow that must be tokenized or given a dark value.

### Dead `dark:` utilities wake up

22 `dark:` utilities exist across `badge`, `button`, `dropdown-menu-item` and
`input` in `components/ui`. **None has ever applied**, because `.dark` has never
been set. Setting it activates them all at once, and they were authored for
shadcn's neutral-slate defaults rather than for warm night paper — for example
`dark:bg-input/30` on every input.

These are reviewed deliberately rather than discovered in passing: each of the
four components is checked in dark mode, and any `dark:` utility that fights
the paper palette is removed or retuned. This is dead code becoming live code,
which no test currently covers.

## Special cases

### Original-document surfaces stay light

Three surfaces render content Valea did not author, where "correct" means
faithful to the source rather than consistent with the app. They are treated as
one policy, not three ad-hoc decisions: **an original document keeps its own
colours, and the app frames it rather than recolouring it.**

**HTML mail.** `HtmlMailView.svelte:49` forces `html{background:#fff}` inside
the sandboxed iframe, and `:50` fixes body ink to `#1c1c1c`. Both stay. Real
email HTML assumes a white background: dark inline text on a dark canvas is
invisible, and rewriting sender HTML breaks inline styles, background images and
logos unpredictably. Dark-mode email is unsolved industry-wide, and a mail client
that mangles messages is worse than one that renders them brightly. The
`.valea-img-unavailable` chip at `:53` keeps its literal light values, since it
sits on that white sheet. The framing border already exists —
`HtmlMailView.svelte:94` is `border-paper-border … bg-white` — so nothing is
added here.

**Plain-text mail must be brought in line.** `MessageView.svelte:857` renders the
non-HTML branch with `bg-paper-card` and `text-ink-body`, and its own comment at
`:852` calls it "the same white reading card the HTML view's iframe provides, so
the two views of one message share a surface". Under the palette swap that
stops being true: the HTML view stays a white sheet while the plain-text view
turns dark, so two views of *the same message* diverge — and the comment becomes
a lie. Plain text is Valea-rendered, not sender-styled, so either it keeps the
white sheet to preserve the stated invariant, or the invariant is retired.
**Decision: plain text keeps the white sheet**, using the same literal white and
dark ink as the iframe, because the promise the comment makes is the right one
and a message should not change character based on its MIME type.

The surrounding chrome does **not** need changing: the message is an `article`
with `gap-6` (`MessageView.svelte:577`), header and actions are a separately
tokenized region (`:578-588`), the body card already carries a tokenized rounded
border (`:857`), and attachments start their own block after it (`:870`). That
is the same dark-chrome-around-a-light-document composition HTML mail already
uses, so the white sheet reads as deliberate rather than unstyled.

**The trap is the link.** `MessageView.svelte:865` styles inline links as
`text-ink-heading … decoration-paper-button-border hover:decoration-ink-secondary`.
Pin only the container and the paragraph and those anchors keep resolving
`--ink-heading`, which in dark is `#efe8d8` — near-white text on a white sheet,
invisible. Every ink the white sheet contains has to be pinned, not just the
body: link colour, underline colour and hover underline colour.

**These cannot be shared as CSS variables across the two branches**, and saying
so would be wrong. `HtmlMailView.svelte:42-44` records why: "the iframe document
can't reach the app's CSS variables, and the CSP allows no external stylesheet."
The iframe is a separate document with its own CSP, so it will always carry
literals in its `srcdoc` string.

The two branches are therefore single-sourced in **TypeScript, not CSS**: a
`mail-document-palette.ts` module exports the sheet's values (background, ink,
link, underline). The iframe interpolates them into its `srcdoc`; the
plain-text branch feeds them to CSS custom properties scoped to the message
card. One definition, two delivery mechanisms, and a test asserting the
plain-text card's computed colours match the constants the iframe was given —
which is the only way the "two views of one message share a surface" invariant
can actually be enforced rather than asserted in a comment.

**PDFs.** `PdfView.svelte` renders pages onto canvases via pdf.js. A typical PDF
is a white page and stays one; nothing recolours it. The dark work is the
*framing* — page gaps, borders and the surrounding scroll surface — which is
tokenized and follows automatically. Verified visually, not assumed.

**Images.** `ImageView.svelte:29` renders a bare `<img>` with a tokenized border.
Source pixels are preserved, which is correct. The known hazard is transparent
PNGs and SVGs authored for a light backing, which can become illegible on dark
paper. Policy: image content is never altered; the image sits on a
`--paper-card` backing so transparency composites against a predictable surface
rather than the canvas.

This makes the result *predictable*, not *legible* — a dark-on-transparent icon
still disappears against dark paper, and only recolouring the image could fix
that, which the policy forbids. Accepted deliberately: silently altering a
user's image is the worse failure. The browser pass checks a dark-on-transparent
PNG so the limitation is seen rather than discovered later.

### Chrome that does not follow the palette

**The Windows close button stays red.** `WindowControls.svelte:228` hardcodes
`hover:bg-[#c42b1c]`. That is the Windows close-affordance red and it is correct
on any background; a platform convention, not a Valea token.

**The dialog overlay needs a dark value.** `dialog-overlay.svelte:15` is
`bg-black/10`. Ten percent black over cream reads as a dim; over an already-dark
canvas it is nearly invisible, so modals lose their separation from the page
exactly where the settings dialog now lives. Dark raises the overlay opacity.

**The favicon and native app icons do not theme.** `app.html:12` always loads
`favicon.png` and `desktop/src-tauri/icons/icon.svg` hardcodes the light
palette. This is deliberate: application identity is stable across themes, the
way it is for every other desktop app. Stated so it is not later filed as a bug.

**The Logo does change, and that is a decision.** `Logo.svelte:9` fills the disc
with `--act`, but the sprig uses `--paper-card` in three places — the stem
stroke at `:14` and the leaf fills at `:21` and `:26`. Under the
palette swap the currently cream sprig becomes dark brown against the green
disc. That is a brand mark changing appearance, not a layout bug. **Decision:
the sprig moves to `--primary-foreground`, all three lines** — the same role-token migration as
[Role tokens vs surface tokens](#role-tokens-vs-surface-tokens) — so the mark
renders identically in both themes.

### The native window background

Tauri paints the native window before the webview has anything to show. The
`theme-init.js` script cannot help there — it runs too late. Whether this
produces a visible light flash on launch in dark mode is **unverified**, and
verifying it is part of the work: launch the desktop app cold in dark mode and
look. If it flashes, the fix is the window background in `tauri.conf.json`; if
that cannot be made theme-aware without a restart, the fallback is a neutral
dark window background, which is unobtrusive under both themes.

## Testing

**Unit**

| File | Covers |
|---|---|
| `stores/theme.test.ts` | `resolveTheme` across all three preferences; persistence round trip; unrecognised values (`"DARK"`, `" dark "`, `null`, a JSON object); no-`localStorage` guard; `getItem` throwing on access; `setItem` throwing after a successful read |
| `stores/theme.test.svelte.ts` | Following an OS change while on `'system'`; **not** following it while pinned to `'light'`/`'dark'`; class and `color-scheme` applied on change; the `matchMedia` listener is removed on teardown and not double-registered across HMR |
| `theme-init.test.ts` | Evaluates the real `static/theme-init.js` against stubbed globals; agrees with `resolveTheme` on all six preference × OS combinations; survives storage that throws |
| `settings/settings-sections.test.ts` | Pins that `agent` and `appearance` are both present and in that order, ids unique, `DEFAULT_SECTION` is a real id |
| `contrast.test.ts` | Every on-accent pairing (`--primary-foreground` over each consequence fill **and over every entry in `AVATAR_FILLS`**) plus `--ink-meta`/`--ink-overline` over each paper surface, in **both** palettes, against the floors in `DESIGN_SYSTEM.md:56` |

The runes test uses the `runes` vitest project added in the issue #4 fix
(`*.test.svelte.ts` + `vitest-env-svelte-client.ts`). `matchMedia` does not
exist in that environment and is stubbed per test.

`contrast.test.ts` is the one that would have caught the `text-paper-card`
defect described in [Role tokens vs surface tokens](#role-tokens-vs-surface-tokens),
which every other test listed here would have passed. It parses the token values
out of `layout.css` so it fails when the palette changes, not when a snapshot
does. It is also the test that fails **today** on two avatar fills, which is the
point — it encodes the invariant `AccountSwitcher.svelte:38` only claims in a
comment.

**Delivery is verified against a build, not a unit test.** Whether
`theme-init.js` is actually referenced and actually served cannot be asserted by
`vitest run`: there is no build prerequisite in `vite.config.ts`, so a test
reading `build/index.html` would pass vacuously on a stale artifact or fail on a
clean checkout. Both failure modes are worse than no test. Instead it is a
release-path check — build, serve through Phoenix, confirm `/theme-init.js`
returns 200 and the class is on `<html>` before first paint — recorded with the
manual checks below. This is the same class of gap that made the CSP problem
invisible: it only exists outside the dev server.

**Not covered by unit tests, deliberately.** There is no DOM component-test
project in this repo (`vite.config.ts` runs Node-based Vitest). Settings nav
selection, `aria-current`, focus movement, Escape-to-close and dirty-state
retention are therefore verified in the browser rather than promised as unit
tests that would need a new test infrastructure to exist first.

**Browser** — every main surface at both themes: Today, Chat, Mail, Calendar,
Files/Knowledge, Tasks, Sources, Audit, Onboarding, and the Settings dialog
itself. Checking default views alone is not sufficient: contrast failures hide
in *states* — hover, selected, active nav, the `refusable` hatch, disabled
buttons, empty states — so those are exercised deliberately.

Surfaces that need looking at specifically, because they are the ones this spec
identified as not following the palette automatically: HTML mail beside
plain-text mail (the same message, both ways), a PDF, a transparent PNG, the
Tiptap bubble menu in its active state, dropdown and popover elevation, the
dialog overlay, the Logo, and the four `components/ui` files whose `dark:`
utilities are newly live.

Also verified: no cream flash on a cold launch with a dark preference (the
production build, not the dev server — the CSP that made this a risk only
applies to the built artifact); theme switching with the Settings dialog open
repaints the dialog itself; and the preference survives a full desktop app quit
and relaunch, not merely a page reload.

**Manual, on hardware I do not have.** Windows and Linux cold launch and native
window paint. Recorded as pending checks in the same style as previous passes
rather than claimed as verified.

## Documentation

- `DESIGN_SYSTEM.md:289` — "Light only; dark mode deferred (unchanged decision)"
  is replaced by the dark palette tables and the dark contrast floor. §2 gains
  the two rules that made this affordable and the one that nearly broke it:
  colour reaches components through tokens rather than literals, *and* a token
  must be chosen for its role rather than its appearance — `--primary-foreground`
  for ink on a consequence fill, never `--paper-card` because it happens to look
  right in light mode.
- `app.html:2-4` and `layout.css:4-8` — comments asserting the app is light-only
  are corrected.
- `MessageView.svelte:852` — the "same white reading card" comment stays true
  only because plain text keeps the white sheet; it gains a note saying so, since
  it is now a cross-theme invariant rather than an incidental match.
- `docs/testing/browser-test-plan.md:61` — B4 is "Dark mode / theme toggle (if
  present)". The parenthetical goes; it is present.

## Rejected alternatives

**Backend app config for the preference.** Considered because it fits the
file-first posture and would survive a storage clear. Rejected because it costs
an RPC round trip on boot, which forces a choice between a light flash and
holding the app blank until it resolves. Theme is a per-machine display
preference — a second monitor at a different desk can reasonably differ — and
`localStorage` is the only store readable early enough to prevent the flash.

**An inline `<script>` in `app.html` for the pre-paint step.** The obvious
approach, and it does not work: the hash-mode CSP in `svelte.config.js` hashes
only SvelteKit-generated scripts, so a hand-written inline script is blocked in
production builds. Measured, not assumed — see
[Applying it before first paint](#applying-it-before-first-paint). Adding the
script's hash to the CSP directives by hand was the alternative fix, and was
rejected because the hash would need regenerating on every edit to the script,
with a launch flash as the only symptom of forgetting.

**Inverting the light palette programmatically.** Rejected: a mechanical
inversion of a warm cream palette gives muddy brown-grey, and it inverts the
consequence colours too, which is exactly the thing that must not drift.

**`role="tablist"` for the settings nav.** Rejected: it promises arrow-key
semantics that would then need implementing and testing, for panes that are not
tabs over a shared dataset.

**Deep-linking sections via the URL (`?settings=appearance`).** Rejected as
YAGNI. The stale copy points users at the gear, not at a link. If a future
section needs addressing from outside, the registry already gives it an id.
