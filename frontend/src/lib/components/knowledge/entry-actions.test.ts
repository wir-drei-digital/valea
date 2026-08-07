import { describe, it, expect } from 'vitest';
import { entryActions, type EntryAction } from './entry-actions';

const base = {
  canReveal: true,
  revealLabel: 'Reveal in Finder',
  canOpenInTab: true,
  openInTabDisabled: null
};

function ids(actions: EntryAction[]): string[] {
  return actions.flatMap((a) => (a.kind === 'action' ? [a.id] : []));
}

describe('entryActions', () => {
  it('offers a page the full set, in order', () => {
    expect(ids(entryActions({ ...base, kind: 'page' }))).toEqual([
      'open-in-tab', 'start-session', 'reveal', 'copy-path', 'copy-name',
      'new-page', 'new-folder', 'rename', 'delete'
    ]);
  });

  it('denies a folder the two leaf actions', () => {
    const list = ids(entryActions({ ...base, kind: 'folder' }));
    expect(list).not.toContain('open-in-tab');
    expect(list).not.toContain('start-session');
    expect(list).toContain('rename');
    expect(list).toContain('delete');
  });

  it('words the session action per kind', () => {
    const label = (kind: 'page' | 'file') =>
      entryActions({ ...base, kind }).find((a) => a.kind === 'action' && a.id === 'start-session');
    expect(label('file')).toMatchObject({ label: 'Start a session with this file' });
    expect(label('page')).toMatchObject({ label: 'Start a session with this page' });
  });

  it('drops reveal entirely when the platform cannot do it', () => {
    expect(ids(entryActions({ ...base, kind: 'file', canReveal: false }))).not.toContain('reveal');
  });

  it('uses the platform label it is handed', () => {
    const list = entryActions({ ...base, kind: 'file', revealLabel: 'Show in Explorer' });
    expect(list.find((a) => a.kind === 'action' && a.id === 'reveal')).toMatchObject({
      label: 'Show in Explorer'
    });
  });

  it('drops open-in-tab when the host offers no such callback', () => {
    expect(ids(entryActions({ ...base, kind: 'file', canOpenInTab: false }))).not.toContain('open-in-tab');
  });

  it('keeps open-in-tab present but disabled when the host gives a reason', () => {
    const action = entryActions({ ...base, kind: 'file', openInTabDisabled: 'The tab strip is full.' })
      .find((a) => a.kind === 'action' && a.id === 'open-in-tab');
    expect(action).toMatchObject({ disabledReason: 'The tab strip is full.' });
  });

  it('marks only delete destructive', () => {
    const destructive = entryActions({ ...base, kind: 'page' })
      .flatMap((a) => (a.kind === 'action' && a.destructive ? [a.id] : []));
    expect(destructive).toEqual(['delete']);
  });

  it('never emits a leading, trailing, or doubled separator', () => {
    for (const kind of ['folder', 'page', 'file'] as const) {
      for (const canReveal of [true, false]) {
        for (const canOpenInTab of [true, false]) {
          const list = entryActions({ ...base, kind, canReveal, canOpenInTab });
          expect(list[0]?.kind, `${kind}/${canReveal}/${canOpenInTab}`).toBe('action');
          expect(list[list.length - 1]?.kind).toBe('action');
          for (let i = 1; i < list.length; i++) {
            expect(list[i].kind === 'separator' && list[i - 1].kind === 'separator').toBe(false);
          }
        }
      }
    }
  });
});
