import { describe, expect, it, vi, afterEach } from 'vitest';
import { readJson, writeJson } from './persist';

// Node 25 defines a global `localStorage` whose methods are undefined — the
// module must survive BOTH a missing localStorage and a broken one. try/catch
// is the guard (Global Constraints).
describe('persist', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('round-trips JSON through a working localStorage', () => {
    const store = new Map<string, string>();
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v)
    });
    writeJson('k', { a: 1 });
    expect(readJson('k')).toEqual({ a: 1 });
  });

  it('readJson returns null for absent keys, malformed JSON, and a broken localStorage', () => {
    const store = new Map<string, string>([['bad', '{not json']]);
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: () => {}
    });
    expect(readJson('missing')).toBeNull();
    expect(readJson('bad')).toBeNull();
    vi.stubGlobal('localStorage', { getItem: undefined, setItem: undefined });
    expect(readJson('k')).toBeNull();
    expect(() => writeJson('k', 1)).not.toThrow();
  });
});
