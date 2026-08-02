import { describe, expect, it } from 'vitest';
import { ancestorHrefs, RevealOnce } from './reveal-path';

describe('ancestorHrefs', () => {
  it('lists every folder above the file, outermost first', () => {
    expect(ancestorHrefs('life', 'finances/records/income/jan.md')).toEqual([
      '/knowledge/life/finances',
      '/knowledge/life/finances/records',
      '/knowledge/life/finances/records/income'
    ]);
  });

  it('returns nothing for a file at the mount root', () => {
    expect(ancestorHrefs('life', 'AGENTS.md')).toEqual([]);
  });

  it('encodes each segment independently', () => {
    expect(ancestorHrefs('m.key', 'ä folder/x.md')).toEqual(['/knowledge/m.key/%C3%A4%20folder']);
  });

  it('returns nothing for an empty path', () => {
    expect(ancestorHrefs('life', '')).toEqual([]);
  });

  // The hrefs are matched against `treeOpenState` keys built by `knowledgeHref`,
  // so the mount key has to be encoded the same way there as it is in the path.
  it('encodes the mount key too', () => {
    expect(ancestorHrefs('my icm', 'notes/x.md')).toEqual(['/knowledge/my%20icm/notes']);
  });

  // A folder is its own ancestor list plus itself; callers that want the folder
  // opened as well (the folder route does) add it themselves.
  it('excludes the file itself, so a one-folder path yields one href', () => {
    expect(ancestorHrefs('life', 'notes/x.md')).toEqual(['/knowledge/life/notes']);
  });
});

describe('RevealOnce', () => {
  it('fires once per key and stays quiet while it is unchanged', () => {
    const gate = new RevealOnce();

    expect(gate.changed('life\0A/doc.md')).toBe(true);
    expect(gate.changed('life\0A/doc.md')).toBe(false);
    expect(gate.changed('life\0A/doc.md')).toBe(false);
  });

  it('fires again when the key changes — a navigation', () => {
    const gate = new RevealOnce();
    gate.changed('life\0A/doc.md');

    expect(gate.changed('life\0A/B/other.md')).toBe(true);
    expect(gate.changed('life\0A/B/other.md')).toBe(false);
  });

  it('treats the same path in another mount as a different key', () => {
    const gate = new RevealOnce();
    gate.changed('life\0A/doc.md');

    expect(gate.changed('work\0A/doc.md')).toBe(true);
  });

  // Returning to a path already revealed is a fresh arrival: the user may have
  // collapsed the folder in between, and navigating back should reveal it again.
  it('fires again on RETURN to a previously revealed key', () => {
    const gate = new RevealOnce();
    gate.changed('life\0A/doc.md');
    gate.changed('life\0B/other.md');

    expect(gate.changed('life\0A/doc.md')).toBe(true);
  });

  it('starts armed, so the very first key always fires', () => {
    expect(new RevealOnce().changed('')).toBe(true);
  });
});
