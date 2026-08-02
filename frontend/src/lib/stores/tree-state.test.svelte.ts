/**
 * Issue #4 — a folder holding the OPEN document could not be collapsed: it
 * flashed shut and sprang straight back open.
 *
 * The route runs a standing `$effect` that reveals the active document's
 * ancestors. The effect wrote expansion state through `TreeOpenState`, and
 * `TreeOpenState` READ that same state on the write path — the short-circuit in
 * `open()` and the key sweep in `#persist()`. Those reads landed inside the
 * effect's dependency set, so the effect subscribed to the very thing it wrote.
 * Collapsing an ancestor invalidated the effect, the effect re-ran, and it
 * re-opened the folder the user had just closed.
 *
 * These tests are the reactive half of `tree-state.test.ts`, which covers the
 * store's plain behaviour. They live in a `*.test.svelte.ts` file because they
 * need real runes: `$effect` only exists in a rune-compiled, client-transformed
 * module (see `vitest-env-svelte-client.ts` — the `runes` project in
 * `vite.config.ts`). Compiled any other way `$effect` disappears and every one
 * of these passes without testing a thing.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { flushSync } from 'svelte';
import { TreeOpenState } from './tree-state.svelte';
import { ancestorHrefs, RevealOnce } from '../shell/reveal-path';

// `#persist()` is the second tracking hazard and it is INERT without storage —
// `hasLocalStorage()` short-circuits before the key sweep. Every test here
// installs the stub so the persist path actually runs.
function installFakeLocalStorage(): void {
  const data = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (key: string) => (data.has(key) ? data.get(key)! : null),
      setItem: (key: string, value: string) => void data.set(key, value),
      removeItem: (key: string) => void data.delete(key),
      clear: () => data.clear()
    },
    configurable: true,
    writable: true
  });
}

function removeLocalStorage(): void {
  // @ts-expect-error - deliberately removing the global again
  delete globalThis.localStorage;
}

describe('TreeOpenState — open() must not subscribe the caller to what it writes', () => {
  beforeEach(() => installFakeLocalStorage());
  afterEach(() => removeLocalStorage());

  it('does not re-run an effect when the href it opened is later closed', () => {
    const state = new TreeOpenState();
    const href = '/knowledge/life/A';
    let runs = 0;

    const stop = $effect.root(() => {
      $effect(() => {
        runs++;
        state.open(href);
      });
    });
    flushSync();
    expect(runs).toBe(1);

    // The user collapses that folder. Nothing the effect READ has changed, so
    // the effect has no business waking up.
    state.toggle(href);
    flushSync();

    expect(runs).toBe(1);
    expect(state.isOpen(href)).toBe(false);
    stop();
  });

  it('does not re-run an effect when an UNRELATED href is toggled', () => {
    // `#persist()` sweeps `Object.keys(#open)`. On a `$state` proxy that is a
    // tracked read of the whole key set, so before the fix an `open()` call
    // subscribed its caller to every add and delete anywhere in the tree.
    const state = new TreeOpenState();
    let runs = 0;

    const stop = $effect.root(() => {
      $effect(() => {
        runs++;
        state.open('/knowledge/life/A');
      });
    });
    flushSync();
    expect(runs).toBe(1);

    state.toggle('/knowledge/life/Somewhere/Else');
    flushSync();

    expect(runs).toBe(1);
    stop();
  });

  it('still notifies a reader that legitimately observes the href', () => {
    // The fix must not go too far: `isOpen()` is what every tree row renders
    // from, and it has to stay reactive.
    const state = new TreeOpenState();
    const href = '/knowledge/life/A';
    const seen: boolean[] = [];

    const stop = $effect.root(() => {
      $effect(() => void seen.push(state.isOpen(href)));
    });
    flushSync();

    state.open(href);
    flushSync();
    state.toggle(href);
    flushSync();

    expect(seen).toEqual([false, true, false]);
    stop();
  });
});

describe('the ancestor reveal (issue #4, as the routes run it)', () => {
  beforeEach(() => installFakeLocalStorage());
  afterEach(() => removeLocalStorage());

  /**
   * Models the reveal effect in `routes/knowledge/[...path]/+page.svelte` and
   * `FilesPane.svelte`: a standing effect over the active path that opens every
   * ancestor href. `active` stands in for the route's `decodedPath`.
   */
  function revealRig(state: TreeOpenState, initialPath: string) {
    const active = $state({ path: initialPath });
    let runs = 0;
    const stop = $effect.root(() => {
      $effect(() => {
        runs++;
        for (const href of ancestorHrefs('life', active.path)) state.open(href);
      });
    });
    flushSync();
    return { active, stop, runs: () => runs };
  }

  it('collapsing a folder that holds the open document STAYS collapsed', () => {
    const state = new TreeOpenState();
    const rig = revealRig(state, 'A/doc.md');

    // Landing on the deep link reveals the folder holding it.
    expect(state.isOpen('/knowledge/life/A')).toBe(true);

    // The user collapses it. Before the fix this flashed shut and sprang back.
    state.toggle('/knowledge/life/A');
    flushSync();

    expect(state.isOpen('/knowledge/life/A')).toBe(false);
    rig.stop();
  });

  it('keeps every ancestor of a deeply nested document collapsible', () => {
    const state = new TreeOpenState();
    const rig = revealRig(state, 'A/B/C/doc.md');

    expect(state.isOpen('/knowledge/life/A')).toBe(true);
    expect(state.isOpen('/knowledge/life/A/B')).toBe(true);
    expect(state.isOpen('/knowledge/life/A/B/C')).toBe(true);

    // Collapsing the OUTERMOST one is the real-world case: it hides the whole
    // subtree, including the row for the open document.
    state.toggle('/knowledge/life/A');
    flushSync();
    expect(state.isOpen('/knowledge/life/A')).toBe(false);

    // An inner one collapses independently and stays that way.
    state.toggle('/knowledge/life/A/B/C');
    flushSync();
    expect(state.isOpen('/knowledge/life/A/B/C')).toBe(false);
    rig.stop();
  });

  it('a tree refetch does not re-reveal what the user collapsed', () => {
    // The route's reveal effect also reads the ICM tree (through `isFolder` ->
    // `node` -> `icmStore.groups`), so ANY `icm_changed` refetch re-runs it.
    // Fixing the store alone leaves that path open: the effect re-runs with an
    // unchanged path and re-opens the ancestors. Same symptom as issue #4, a
    // different trigger — so the reveal has to be gated on the path CHANGING,
    // not merely on the effect running.
    const state = new TreeOpenState();
    const groups = $state({ version: 0 });
    const gate = new RevealOnce();
    const stop = $effect.root(() => {
      $effect(() => {
        void groups.version;
        if (!gate.changed(`life\0A/doc.md`)) return;
        for (const href of ancestorHrefs('life', 'A/doc.md')) state.open(href);
      });
    });
    flushSync();

    state.toggle('/knowledge/life/A');
    flushSync();
    expect(state.isOpen('/knowledge/life/A')).toBe(false);

    groups.version++; // an icm_changed refetch lands
    flushSync();

    expect(state.isOpen('/knowledge/life/A')).toBe(false);
    stop();
  });

  it('still reveals on NAVIGATION, including folders the user had collapsed', () => {
    // The behaviour the bug was protecting: a deep link lands with its location
    // visible. Navigating to a new document must reveal its ancestors even if
    // the user closed them earlier — that is a fresh intent, not a fight.
    const state = new TreeOpenState();
    const rig = revealRig(state, 'A/doc.md');

    state.toggle('/knowledge/life/A');
    flushSync();
    expect(state.isOpen('/knowledge/life/A')).toBe(false);

    rig.active.path = 'A/B/other.md';
    flushSync();

    expect(state.isOpen('/knowledge/life/A')).toBe(true);
    expect(state.isOpen('/knowledge/life/A/B')).toBe(true);
    rig.stop();
  });
});
