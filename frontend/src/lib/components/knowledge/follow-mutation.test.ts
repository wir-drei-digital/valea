import { describe, expect, it } from 'vitest';
import { followMutation } from './follow-mutation';
import { serializePaneParam, type PaneDescriptor } from '$lib/panes/pane-route';

const chat: PaneDescriptor = { kind: 'chat', sessionId: 'sess-123' };

function at(href: string): URL {
  return new URL(href, 'https://valea.test');
}

function panesOf(href: string): string[] {
  return new URL(href, 'https://valea.test').searchParams.getAll('pane');
}

const file = { mountKey: 'life', path: 'planning/CONTEXT.md', isFolder: false };
const folder = { mountKey: 'life', path: 'planning', isFolder: true };

describe('followMutation — the route primary', () => {
  it('follows a rename of the open page', () => {
    const out = followMutation(at('/knowledge/life/planning/CONTEXT.md'), file, 'planning/NOTES.md');
    expect(out).toBe('/knowledge/life/planning/NOTES.md');
  });

  it('sends a deleted open page back to the index, on its own mount', () => {
    const out = followMutation(at('/knowledge/life/planning/CONTEXT.md'), file, null);
    expect(out).toBe('/knowledge?icm=life');
  });

  it('carries the pane composition through both', () => {
    const url = at(`/knowledge/life/planning/CONTEXT.md?pane=${serializePaneParam(chat)}`);
    expect(panesOf(followMutation(url, file, 'planning/NOTES.md')!)).toEqual([
      serializePaneParam(chat)
    ]);
    expect(panesOf(followMutation(url, file, null)!)).toEqual([serializePaneParam(chat)]);
  });

  it('leaves a route that is not showing the entry alone', () => {
    expect(followMutation(at('/knowledge/life/OTHER.md'), file, 'planning/NOTES.md')).toBeNull();
    expect(followMutation(at('/chat?session=a91f'), file, null)).toBeNull();
  });

  it('does not touch another mount that happens to use the same path', () => {
    expect(followMutation(at('/knowledge/valea/planning/CONTEXT.md'), file, null)).toBeNull();
  });

  it('moves a page nested under a renamed folder', () => {
    const out = followMutation(at('/knowledge/life/planning/CONTEXT.md'), folder, 'strategy');
    expect(out).toBe('/knowledge/life/strategy/CONTEXT.md');
  });

  it('does not treat a leaf as a prefix of its neighbours', () => {
    // `planning` as a FILE must not swallow `planning/CONTEXT.md`; only the
    // folder form carries descendants.
    const leaf = { mountKey: 'life', path: 'planning', isFolder: false };
    expect(followMutation(at('/knowledge/life/planning/CONTEXT.md'), leaf, 'strategy')).toBeNull();
  });

  it('does not match a sibling whose name merely starts the same', () => {
    // `planning` must not carry `planning-archive/OLD.md`.
    expect(followMutation(at('/knowledge/life/planning-archive/OLD.md'), folder, 'strategy')).toBeNull();
  });
});

describe('followMutation — the primary’s other tabs (?tabs=)', () => {
  it('follows a rename of a file in a tab that is not showing', () => {
    const out = followMutation(
      at('/knowledge/life/AGENTS.md?tabs=AGENTS.md|planning%2FCONTEXT.md'),
      file,
      'planning/NOTES.md'
    );
    const url = at(out!);
    expect(url.pathname).toBe('/knowledge/life/AGENTS.md');
    expect(url.searchParams.get('tabs')).toBe('AGENTS.md|planning/NOTES.md');
  });

  it('drops a deleted tab and keeps the rest of the strip open', () => {
    const out = followMutation(
      at('/knowledge/life/AGENTS.md?tabs=AGENTS.md|planning%2FCONTEXT.md'),
      file,
      null
    );
    expect(out).toBe('/knowledge/life/AGENTS.md');
  });

  it('shows a surviving tab when the one being READ is deleted', () => {
    // The alternative — bouncing to the index — would discard a file the user
    // still has open, and any unsaved edit in it.
    const out = followMutation(
      at('/knowledge/life/planning/CONTEXT.md?tabs=planning%2FCONTEXT.md|AGENTS.md'),
      file,
      null
    );
    expect(out).toBe('/knowledge/life/AGENTS.md');
  });

  // The index is an INDEX, and a delete renumbers the strip under it. Holding
  // the old one would show whatever slid into that slot.
  it('keeps showing the same FILE when an earlier tab is deleted', () => {
    const out = followMutation(
      at('/knowledge/life/AGENTS.md?tabs=planning%2FCONTEXT.md|AGENTS.md|NOTES.md'),
      file,
      null
    );
    const url = at(out!);
    expect(url.pathname).toBe('/knowledge/life/AGENTS.md');
    expect(url.searchParams.get('tabs')).toBe('AGENTS.md|NOTES.md');
  });

  it('renumbers compare around a deleted tab', () => {
    const out = followMutation(
      at('/knowledge/life/NOTES.md?tabs=planning%2FCONTEXT.md|AGENTS.md|NOTES.md&compare=1'),
      file,
      null
    );
    const url = at(out!);
    expect(url.pathname).toBe('/knowledge/life/NOTES.md');
    expect(url.searchParams.get('tabs')).toBe('AGENTS.md|NOTES.md');
    expect(url.searchParams.get('compare')).toBe('0');
  });

  it('drops compare when the file beside the active tab is the one deleted', () => {
    const out = followMutation(
      at('/knowledge/life/AGENTS.md?tabs=AGENTS.md|planning%2FCONTEXT.md&compare=1'),
      file,
      null
    );
    expect(at(out!).searchParams.get('compare')).toBeNull();
  });

  it('goes to the index only when EVERY tab is gone', () => {
    const out = followMutation(
      at('/knowledge/life/planning/CONTEXT.md?tabs=planning%2FCONTEXT.md|planning%2FPLAN.md'),
      folder,
      null
    );
    expect(out).toBe('/knowledge?icm=life');
  });
});

describe('followMutation — Files panes', () => {
  const paneUrl = (paneParam: string, path = '/chat') =>
    at(`${path}?pane=${encodeURIComponent(paneParam)}`);

  it('follows a rename inside a pane on a route that shows no file at all', () => {
    // The bug this function exists for: a pathname comparison never sees a
    // file that lives only in `?pane=`.
    const out = followMutation(
      paneUrl('files:life/planning%2FCONTEXT.md'),
      file,
      'planning/NOTES.md'
    );
    expect(panesOf(out!)).toEqual(['files:life/planning/NOTES.md']);
    expect(at(out!).pathname).toBe('/chat');
  });

  it('drops a deleted file from a pane and keeps its sibling split', () => {
    const out = followMutation(paneUrl('files:life/planning%2FCONTEXT.md|AGENTS.md'), file, null);
    expect(panesOf(out!)).toEqual(['files:life/AGENTS.md']);
  });

  it('leaves the pane open with its tree when the last file goes', () => {
    // Spec: a Files pane with no files left survives as tree-only. Closing it
    // would take the navigator away as collateral for one deleted file.
    const out = followMutation(paneUrl('files:life/planning%2FCONTEXT.md'), file, null);
    expect(panesOf(out!)).toEqual(['files:life']);
  });

  it('ignores a Files pane on a different mount', () => {
    expect(followMutation(paneUrl('files:valea/planning%2FCONTEXT.md'), file, null)).toBeNull();
  });

  it('ignores panes that are not Files panes', () => {
    expect(followMutation(paneUrl(serializePaneParam(chat)), file, null)).toBeNull();
  });

  it('rewrites the pane AND the primary in one navigation', () => {
    const url = at(
      '/knowledge/life/planning/CONTEXT.md?pane=' +
        encodeURIComponent('files:life/planning%2FPLAN.md')
    );
    // Same-kind dedup means this composition cannot occur in the app; the
    // point here is that both halves are computed from the same URL and
    // emitted together, never as two navigations that race.
    const out = followMutation(url, folder, 'strategy');
    expect(at(out!).pathname).toBe('/knowledge/life/strategy/CONTEXT.md');
    expect(panesOf(out!)).toEqual(['files:life/strategy/PLAN.md']);
  });
});
