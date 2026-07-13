import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { recordVisit, recentPages } from './recent-pages';

/**
 * The vitest run here executes without a DOM (no jsdom/happy-dom
 * dependency, see `vitest.config.ts`), so the global `localStorage` this
 * module guards against (`typeof localStorage`) is genuinely absent by
 * default — the same condition an SSR/non-browser context would see. Tests
 * that exercise the persisted round-trip install a minimal in-memory stub
 * for the duration of the test and remove it afterward; the guard test
 * below runs with no stub at all.
 */
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

describe('recent-pages — no localStorage (SSR/guard)', () => {
  beforeEach(() => removeLocalStorage());

  it('recentPages returns an empty array when localStorage is unavailable', () => {
    expect(recentPages()).toEqual([]);
  });

  it('recordVisit does not throw when localStorage is unavailable', () => {
    expect(() => recordVisit('Notes/A.md')).not.toThrow();
  });
});

describe('recent-pages — persisted round trip', () => {
  beforeEach(() => installFakeLocalStorage());
  afterEach(() => removeLocalStorage());

  it('starts empty', () => {
    expect(recentPages()).toEqual([]);
  });

  it('records a visit and returns it', () => {
    recordVisit('Notes/A.md');
    expect(recentPages()).toEqual(['Notes/A.md']);
  });

  it('orders most-recent-first', () => {
    recordVisit('Notes/A.md');
    recordVisit('Notes/B.md');
    recordVisit('Notes/C.md');
    expect(recentPages()).toEqual(['Notes/C.md', 'Notes/B.md', 'Notes/A.md']);
  });

  it('dedupes — revisiting a page moves it to the front instead of duplicating it', () => {
    recordVisit('Notes/A.md');
    recordVisit('Notes/B.md');
    recordVisit('Notes/A.md');
    expect(recentPages()).toEqual(['Notes/A.md', 'Notes/B.md']);
  });

  it('caps at 10 entries, dropping the oldest', () => {
    for (let i = 1; i <= 12; i++) {
      recordVisit(`Notes/${i}.md`);
    }
    const result = recentPages();
    expect(result).toHaveLength(10);
    expect(result[0]).toBe('Notes/12.md');
    expect(result).not.toContain('Notes/1.md');
    expect(result).not.toContain('Notes/2.md');
  });

  it('survives a corrupted stored value rather than throwing', () => {
    localStorage.setItem('valea.recent-pages', '{not json');
    expect(recentPages()).toEqual([]);
  });

  it('ignores a stored value that is not an array', () => {
    localStorage.setItem('valea.recent-pages', JSON.stringify({ not: 'an array' }));
    expect(recentPages()).toEqual([]);
  });
});
