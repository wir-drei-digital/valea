import { describe, expect, it } from 'vitest';
import { dropSubject, replaceAt } from './pane-edit';
import type { PaneDescriptor } from './pane-route';

const chat: PaneDescriptor = { kind: 'chat', sessionId: 's1' };
const mail: PaneDescriptor = { kind: 'mail', account: 'mara@example.com', msgId: '8842' };
const filesTwo: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['A.md', 'B.md'] };
const filesOne: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['A.md'] };

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
  it('drops one split and keeps its sibling', () => {
    expect(dropSubject(filesTwo, 'A.md')).toEqual({
      kind: 'files',
      mountKey: 'life',
      paths: ['B.md']
    });
  });

  it('leaves a Files pane open as its tree when the last file goes', () => {
    expect(dropSubject(filesOne, 'A.md')).toEqual({ kind: 'files', mountKey: 'life', paths: [] });
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
