import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { TreeOpenState } from './tree-state.svelte';

// Same no-DOM storage stubbing pattern as `recent-pages.test.ts` (see its
// header comment): the guard tests run with no `localStorage` at all; the
// round-trip tests install an in-memory stub and construct FRESH
// `TreeOpenState` instances (hydration happens at construction).
function installFakeLocalStorage(): void {
  const data = new Map<string, string>();
  const fake = {
    getItem: (key: string) => (data.has(key) ? data.get(key)! : null),
    setItem: (key: string, value: string) => {
      data.set(key, value);
    },
    removeItem: (key: string) => {
      data.delete(key);
    },
    clear: () => data.clear()
  };
  Object.defineProperty(globalThis, 'localStorage', { value: fake, configurable: true, writable: true });
}

function removeLocalStorage(): void {
  // @ts-expect-error - deliberately deleting the global for the guard test
  delete globalThis.localStorage;
}

describe('TreeOpenState — no localStorage (SSR/guard)', () => {
  beforeEach(() => removeLocalStorage());

  it('defaults every row to CLOSED and toggles in memory without throwing', () => {
    const state = new TreeOpenState();

    expect(state.isOpen('/knowledge/primary/Offers')).toBe(false);
    expect(() => state.toggle('/knowledge/primary/Offers')).not.toThrow();
    expect(state.isOpen('/knowledge/primary/Offers')).toBe(true);
  });
});

describe('TreeOpenState — persisted round trip', () => {
  beforeEach(() => installFakeLocalStorage());
  afterEach(() => removeLocalStorage());

  it('persists opened rows across instances (a reload keeps the last opened folders open)', () => {
    const state = new TreeOpenState();
    state.toggle('/knowledge/primary/Offers');
    state.open('/knowledge/primary/Offers/Archive');

    const reloaded = new TreeOpenState();
    expect(reloaded.isOpen('/knowledge/primary/Offers')).toBe(true);
    expect(reloaded.isOpen('/knowledge/primary/Offers/Archive')).toBe(true);
    expect(reloaded.isOpen('/knowledge/primary/Other')).toBe(false);
  });

  it('toggle closes an open row and drops it from storage', () => {
    const state = new TreeOpenState();
    state.toggle('/knowledge/primary/Offers');
    state.toggle('/knowledge/primary/Offers');

    expect(state.isOpen('/knowledge/primary/Offers')).toBe(false);
    expect(new TreeOpenState().isOpen('/knowledge/primary/Offers')).toBe(false);
  });

  it('open() is idempotent', () => {
    const state = new TreeOpenState();
    state.open('/knowledge/primary/Offers');
    state.open('/knowledge/primary/Offers');

    expect(state.isOpen('/knowledge/primary/Offers')).toBe(true);
  });

  it('tolerates corrupted storage by starting closed', () => {
    localStorage.setItem('valea.tree-open', '{not json');
    expect(new TreeOpenState().isOpen('/knowledge/primary/Offers')).toBe(false);

    localStorage.setItem('valea.tree-open', JSON.stringify({ nope: true }));
    expect(new TreeOpenState().isOpen('/knowledge/primary/Offers')).toBe(false);
  });
});
