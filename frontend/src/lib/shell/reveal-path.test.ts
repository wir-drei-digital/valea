import { describe, expect, it } from 'vitest';
import { ancestorHrefs } from './reveal-path';

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
