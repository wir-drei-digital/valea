import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { paneWiring } from './pane-wiring';
import { alreadyOpenRefusal } from './pane-offer';
import { dedupeSurfaces, parsePanes, type PaneDescriptor } from './pane-route';

/**
 * `pane-wiring.ts` holds no runes — it is a plain closure over thunks — so it
 * is testable without the effect harness this repo does not have. Only
 * `$app/navigation` needs standing in for, and only to record the href.
 *
 * The harness below is deliberately the shape of a real host: `panes` is
 * DERIVED from the URL, and `land()` applies the navigation the wiring just
 * issued. That is the whole reason the module's bugs have been invisible to
 * reasoning — the claim it leaves behind has to survive a round trip through
 * the URL and be picked up by whatever pane exists on the other side. A test
 * that fed `panes` in directly would never exercise that at all.
 */
const nav = vi.hoisted(() => ({ hrefs: [] as string[] }));

vi.mock('$app/navigation', () => ({
  goto: (href: string) => {
    nav.hrefs.push(href);
    return Promise.resolve();
  }
}));

const ORIGIN = 'http://localhost';

function host(initial: string, primary: PaneDescriptor | null = null, slots?: () => number) {
  let url = new URL(initial, ORIGIN);
  const panes = () => dedupeSurfaces(primary, parsePanes(url.searchParams));
  const wiring = paneWiring({ url: () => url, panes, primary: () => primary, slots });

  return {
    wiring,
    panes,
    url: () => url,
    /** Apply the navigation the wiring issued, exactly as the router would. */
    land() {
      const href = nav.hrefs.at(-1);
      if (href) url = new URL(href, ORIGIN);
      return this;
    },
    /** The context the host would build for the pane now in `index`. */
    context(index = 0) {
      return wiring.paneContext(panes()[index], index);
    },
    navigated: () => nav.hrefs.length
  };
}

beforeEach(() => {
  nav.hrefs.length = 0;
});

const life = 'files:life';

describe('openFileSurface — creating a Files surface', () => {
  it('opens a pane for the file when there is no Files surface', () => {
    const h = host('/chat?session=s1');
    h.wiring.openFileSurface({ mountKey: 'w3d', path: 'CONTEXT.md' });
    h.land();
    expect(h.panes()).toEqual([
      { kind: 'files', mountKey: 'w3d', paths: ['CONTEXT.md'], active: 0, compare: null }
    ]);
  });

  it('leaves the claim for the pane it created to pick up', () => {
    // The created pane's file lands BEFORE the component exists, so nothing
    // can record the claim as it is made. Without the handover the assistant's
    // first read is stranded in a split it can never recycle.
    const h = host('/chat?session=s1');
    h.wiring.openFileSurface({ mountKey: 'w3d', path: 'CONTEXT.md' });
    h.land();
    expect(h.context().takeAutoCreatedPath?.()).toBe('CONTEXT.md');
  });

  it('refuses to grow a third pane', () => {
    const h = host('/chat?pane=mail:a@b.c&pane=chat:s2');
    h.wiring.openFileSurface({ mountKey: 'w3d', path: 'CONTEXT.md' });
    expect(h.navigated()).toBe(0);
  });

  it('hands the file to the route when the route owns the Files surface', () => {
    const openInPrimary = vi.fn();
    const url = new URL('/knowledge/life/A.md', ORIGIN);
    const wiring = paneWiring({
      url: () => url,
      panes: () => [],
      openInPrimary
    });
    wiring.openFileSurface({ mountKey: 'life', path: 'B.md' });
    expect(openInPrimary).toHaveBeenCalledWith({ mountKey: 'life', path: 'B.md' });
    expect(nav.hrefs.length).toBe(0);
  });
});

describe('openFileSurface — a file from another ICM', () => {
  it('re-points the pane instead of pushing a foreign path into the old mount', () => {
    // `{ ...pane, paths }` would keep `mountKey: 'life'` and produce
    // `files:life/CONTEXT.md` for a file that only exists in `w3d`.
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    h.wiring.openFileSurface({ mountKey: 'w3d', path: 'CONTEXT.md' });
    h.land();
    expect(h.panes()).toEqual([
      { kind: 'files', mountKey: 'w3d', paths: ['CONTEXT.md'], active: 0, compare: null }
    ]);
  });

  it('leaves the claim for the re-pointed pane to pick up', () => {
    // The same boundary as a created pane: the mount is part of a pane's
    // identity, so the host builds fresh state and the claim has to be left
    // behind for it. Missing here, the split is never recycled and never
    // released — the next read takes the other one and the pane is half dead.
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    h.wiring.openFileSurface({ mountKey: 'w3d', path: 'CONTEXT.md' });
    h.land();
    expect(h.context().takeAutoCreatedPath?.()).toBe('CONTEXT.md');
  });
});

describe('openFileSurface — a file in the ICM the pane already shows', () => {
  it('hands the file to the mounted pane rather than placing it', () => {
    // Where it lands depends on the claim and on the pane's measured width,
    // neither of which is visible from out here.
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    const received: string[] = [];
    h.context().registerFileTarget?.((path) => received.push(path));

    h.wiring.openFileSurface({ mountKey: 'life', path: 'CONTEXT.md' });
    expect(received).toEqual(['CONTEXT.md']);
    expect(h.navigated()).toBe(0);
  });

  it('falls back to the claimless floor when no pane has announced itself', () => {
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    h.wiring.openFileSurface({ mountKey: 'life', path: 'CONTEXT.md' });
    h.land();
    // The assistant's file is the one to SHOW: a tab that arrives behind the
    // one you are reading is a citation you never see.
    expect(h.panes()).toEqual([
      {
        kind: 'files',
        mountKey: 'life',
        paths: ['AGENTS.md', 'CONTEXT.md'],
        active: 1,
        compare: null
      }
    ]);
  });

  it('claims nothing on the fallback — the pane is already there to record it', () => {
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    h.wiring.openFileSurface({ mountKey: 'life', path: 'CONTEXT.md' });
    h.land();
    expect(h.context().takeAutoCreatedPath?.()).toBeNull();
  });
});

describe('takeAutoCreatedPath', () => {
  it('is one-shot — a second ask returns null', () => {
    // Re-registration is routine (the host hands down a fresh context object
    // on every render), so an answer that repeated would let a claim be
    // re-applied to a split the user has since taken over.
    const h = host('/chat?session=s1');
    h.wiring.openFileSurface({ mountKey: 'w3d', path: 'CONTEXT.md' });
    h.land();
    const context = h.context();
    expect(context.takeAutoCreatedPath?.()).toBe('CONTEXT.md');
    expect(context.takeAutoCreatedPath?.()).toBeNull();
  });

  it('is null when nothing was opened at all', () => {
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    expect(h.context().takeAutoCreatedPath?.()).toBeNull();
  });

  it('is null after a file the USER opened', () => {
    // A tree click rewrites the pane's own descriptor through `openPane`. The
    // user placed that file, so nothing may claim it — a claim is a licence to
    // overwrite, and this is the split the rule exists to protect.
    const h = host(`/chat?pane=${life}/AGENTS.md`);
    h.context().openPane?.({
      kind: 'files',
      mountKey: 'life',
      paths: ['CONTEXT.md'],
      active: 0,
      compare: null
    });
    h.land();
    expect(h.panes()).toEqual([
      { kind: 'files', mountKey: 'life', paths: ['CONTEXT.md'], active: 0, compare: null }
    ]);
    expect(h.context().takeAutoCreatedPath?.()).toBeNull();
  });
});

describe('openBeside — the gate every pane-opening control shares', () => {
  const session: PaneDescriptor = { kind: 'chat', sessionId: 's9' };

  it('appends the pane when the window has room', () => {
    const h = host('/knowledge/life/A.md', null, () => 2);
    h.wiring.openBeside(session);
    h.land();
    expect(h.panes()).toEqual([session]);
  });

  it('refuses when the window has no room for another pane', () => {
    // The bug this closes: at a 900px window `panesThatFit` is 0, the bar's
    // ＋ Pane was correctly disabled, and this control — six pixels above it —
    // opened a chat into a ~130px column anyway. Every control disables itself
    // with the reason; this is the guard behind it, which also covers
    // keyboard activation of an `aria-disabled` button.
    const h = host('/knowledge/life/A.md', null, () => 0);
    h.wiring.openBeside(session);
    expect(h.navigated()).toBe(0);
    expect(h.panes()).toEqual([]);
  });

  it('has no opinion for a route that supplies none', () => {
    // Absent means absent, not zero: a route with no such control must not
    // have its own `openBeside` silently disabled by an unset option.
    const h = host('/knowledge/life/A.md');
    h.wiring.openBeside(session);
    h.land();
    expect(h.panes()).toEqual([session]);
  });

  it('refuses a full row even when the window says there is room', () => {
    // The cap outranks the width — `PANE_CAP` is the one refusal no monitor
    // can lift, and the room reader must not be able to talk past it.
    const h = host(`/knowledge/life/A.md?pane=${life}&pane=mail:me@x.test`, null, () => 9);
    expect(h.panes()).toHaveLength(2);
    h.wiring.openBeside(session);
    expect(h.navigated()).toBe(0);
  });

  it('refuses a kind the ROUTE PRIMARY already shows, rather than dropping it in dedupe', () => {
    // Without the kind check this navigates, `dedupeSurfaces` drops the new
    // pane on the way to the URL, and the control appears broken — the exact
    // silent no-op the reason exists to replace.
    const primary: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: [], active: 0, compare: null };
    const h = host('/knowledge/life/A.md', primary, () => 2);
    h.wiring.openBeside({ kind: 'files', mountKey: 'life', paths: [], active: 0, compare: null });
    expect(h.navigated()).toBe(0);
    expect(h.wiring.besideRefusal('files')).toBe(alreadyOpenRefusal('files'));
  });

  it('refuses a kind an open PANE already shows', () => {
    const h = host(`/knowledge/life/A.md?pane=chat:s1`, null, () => 2);
    h.wiring.openBeside(session);
    expect(h.navigated()).toBe(0);
    expect(h.wiring.besideRefusal('chat')).toBe(alreadyOpenRefusal('chat'));
  });

  it('reports no refusal, and opens, when the row and the width both allow it', () => {
    const h = host('/knowledge/life/A.md', null, () => 2);
    expect(h.wiring.besideRefusal('chat')).toBeNull();
    h.wiring.openBeside(session);
    expect(h.navigated()).toBe(1);
  });

  it('gives a pane-placed view the same answer the route gets', () => {
    // A chat pane opening a file browser beside itself must meet the same gate
    // as the route's own control, or the two placements disagree about the row.
    const h = host(`/knowledge/life/A.md?pane=chat:s1`, null, () => 1);
    expect(h.context().besideRefusal?.('files')).toBe(h.wiring.besideRefusal('files'));
    h.context().openBeside?.({ kind: 'files', mountKey: 'life', paths: [], active: 0, compare: null });
    expect(h.navigated()).toBe(0);
  });
});

describe('besideOpen / closeBeside — the other half of a toggle', () => {
  it('reports only PANES, never the route primary', () => {
    // `besideRefusal` deliberately counts the primary too, because
    // `dedupeSurfaces` does. This one must not: a control that toggled on the
    // primary would offer to close a pane that does not exist.
    const primary: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: [], active: 0, compare: null };
    const h = host('/knowledge/life/A.md', primary, () => 2);
    expect(h.wiring.besideRefusal('files')).toBe(alreadyOpenRefusal('files'));
    expect(h.wiring.besideOpen('files')).toBe(false);
  });

  it('reports a pane of that kind, and closes it', () => {
    const h = host(`/chat?session=s1&pane=${life}`);
    expect(h.wiring.besideOpen('files')).toBe(true);
    h.wiring.closeBeside('files');
    h.land();
    expect(h.panes()).toEqual([]);
    expect(h.wiring.besideOpen('files')).toBe(false);
  });

  it('leaves the other panes alone', () => {
    const h = host(`/chat?session=s1&pane=${life}&pane=mail:me@x.test`);
    h.wiring.closeBeside('files');
    h.land();
    expect(h.panes()).toEqual([{ kind: 'mail', account: 'me@x.test', msgId: null }]);
  });

  it('does nothing when no pane of that kind is open', () => {
    const h = host('/chat?session=s1');
    h.wiring.closeBeside('files');
    expect(h.navigated()).toBe(0);
  });
});

describe('reopening a file browser', () => {
  // These are the only wiring tests that need storage: closing a Files pane
  // writes what it had open, and opening an EMPTY one reads it back.
  function installFakeLocalStorage(): void {
    const data = new Map<string, string>();
    Object.defineProperty(globalThis, 'localStorage', {
      value: {
        getItem: (key: string) => (data.has(key) ? data.get(key)! : null),
        setItem: (key: string, value: string) => void data.set(key, value),
        removeItem: (key: string) => void data.delete(key),
        clear: () => data.clear()
      },
      configurable: true,
      writable: true
    });
  }

  beforeEach(() => installFakeLocalStorage());
  afterEach(() => {
    // @ts-expect-error - restoring the node environment's missing global
    delete globalThis.localStorage;
  });

  /** Two tabs, the second showing — `notes/B.md` is per-segment encoded. */
  const opened = 'files:life/A.md|notes%2FB.md@1';
  const emptyBrowser: PaneDescriptor = {
    kind: 'files',
    mountKey: 'life',
    paths: [],
    active: 0,
    compare: null
  };

  it('comes back with the tabs it was closed with', () => {
    // THE flow: open the browser from a session, read two files, close it to
    // give the transcript the width, open it again. Reopening to an empty pane
    // costs every tab and makes the toggle expensive to use.
    const h = host(`/chat?session=s1&pane=${opened}`);
    h.wiring.closeBeside('files');
    h.land();
    expect(h.panes()).toEqual([]);

    h.wiring.openBeside(emptyBrowser);
    h.land();
    expect(h.panes()).toEqual([
      { kind: 'files', mountKey: 'life', paths: ['A.md', 'notes/B.md'], active: 1, compare: null }
    ]);
  });

  it('opens empty when that ICM has no browser to remember', () => {
    const h = host('/chat?session=s1');
    h.wiring.openBeside(emptyBrowser);
    h.land();
    expect(h.panes()).toEqual([emptyBrowser]);
  });

  it('never overrides a caller that named a file', () => {
    // A citation, a link, a cross-ICM re-point: those callers know exactly
    // what they want shown, and substituting yesterday's tabs would bury it.
    const h = host(`/chat?session=s1&pane=${opened}`);
    h.wiring.closeBeside('files');
    h.land();
    const named: PaneDescriptor = {
      kind: 'files',
      mountKey: 'life',
      paths: ['C.md'],
      active: 0,
      compare: null
    };
    h.wiring.openBeside(named);
    h.land();
    expect(h.panes()).toEqual([named]);
  });

  it('remembers per ICM', () => {
    const h = host(`/chat?session=s1&pane=${opened}`);
    h.wiring.closeBeside('files');
    h.land();
    h.wiring.openBeside({ ...emptyBrowser, mountKey: 'w3d' });
    h.land();
    expect(h.panes()).toEqual([{ ...emptyBrowser, mountKey: 'w3d' }]);
  });
});
