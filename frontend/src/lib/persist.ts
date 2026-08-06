/**
 * Guarded localStorage JSON — the ONE place storage is touched (Global
 * Constraints). try/catch is the real guard: Node 25 ships a global
 * `localStorage` whose methods are undefined, so feature-detection by
 * `typeof` lies. Failures read as null / write as no-op; persistence is an
 * enhancement, never a dependency.
 */
export function readJson(key: string): unknown {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? null : JSON.parse(raw);
  } catch {
    return null;
  }
}

export function writeJson(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // storage unavailable or full — the in-memory state stays authoritative
  }
}
