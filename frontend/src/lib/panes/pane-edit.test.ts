import { describe, expect, it } from 'vitest';
import { dropSubject, replaceAt } from './pane-edit';
import type { FilesPaneDescriptor, PaneDescriptor } from './pane-route';

const chat: PaneDescriptor = { kind: 'chat', sessionId: 's1' };
const mail: PaneDescriptor = { kind: 'mail', account: 'mara@example.com', msgId: '8842' };
function files(paths: string[], active = 0, compare: number | null = null): FilesPaneDescriptor {
  return { kind: 'files', mountKey: 'life', paths, active, compare };
}

const filesTwo = files(['A.md', 'B.md']);
const filesOne = files(['A.md']);

describe('replaceAt', () => {
  it('replaces the pane at the index', () => {
    expect(replaceAt([chat, filesOne], 1, mail)).toEqual([chat, mail]);
  });

  it('removes the pane when handed null', () => {
    expect(replaceAt([chat, filesOne], 0, null)).toEqual([filesOne]);
  });

  it('ignores an index outside the row', () => {
    // A callback from a pane that has already left must not corrupt the list.
    expect(replaceAt([chat], 5, mail)).toEqual([chat]);
    expect(replaceAt([chat], -1, null)).toEqual([chat]);
  });

  it('always allocates, even when nothing changed', () => {
    // The host stops re-deriving its row layout when handed the same array
    // identity, and paneforge then writes stale sizes back over a drag.
    const panes = [chat];
    expect(replaceAt(panes, 5, mail)).not.toBe(panes);
    expect(replaceAt(panes, 0, chat)).not.toBe(panes);
  });

  it('never mutates the array it was given', () => {
    const panes = [chat, filesOne];
    replaceAt(panes, 0, null);
    replaceAt(panes, 1, mail);
    expect(panes).toEqual([chat, filesOne]);
  });
});

describe('dropSubject', () => {
  it('drops one tab and keeps its siblings', () => {
    expect(dropSubject(filesTwo, 'A.md')).toEqual(files(['B.md']));
  });

  it('leaves a Files pane open as its tree when the last file goes', () => {
    expect(dropSubject(filesOne, 'A.md')).toEqual(files([]));
  });

  // The cursor is an INDEX into a list this shortens, so it has to move with
  // it: a stale `active` renders the wrong file, and a stale `compare` puts a
  // file beside itself or points past the end.
  it('renumbers the active tab and compare around the tab it drops', () => {
    expect(dropSubject(files(['A.md', 'B.md', 'C.md'], 2, 1), 'A.md')).toEqual(
      files(['B.md', 'C.md'], 1, 0)
    );
  });

  it('falls back to the neighbour when the tab being read is the one dropped', () => {
    expect(dropSubject(files(['A.md', 'B.md', 'C.md'], 1), 'B.md')).toEqual(
      files(['A.md', 'C.md'], 0)
    );
  });

  it('turns compare off when the file beside the active tab is the one dropped', () => {
    expect(dropSubject(files(['A.md', 'B.md'], 0, 1), 'B.md')).toEqual(files(['A.md'], 0));
  });

  it('closes a single-subject pane outright', () => {
    expect(dropSubject(chat, 's1')).toBeNull();
    expect(dropSubject(mail, '8842')).toBeNull();
  });

  it('returns the pane unchanged when the subject was not its own', () => {
    // Same identity is how the caller tells "nothing happened" from "the
    // descriptor moved", without a second return flag to keep in step.
    expect(dropSubject(filesTwo, 'C.md')).toBe(filesTwo);
  });

  it('does not mutate the descriptor it was given', () => {
    dropSubject(filesTwo, 'A.md');
    expect(filesTwo.paths).toEqual(['A.md', 'B.md']);
  });
});
