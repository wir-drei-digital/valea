import { beforeEach, describe, expect, it, vi } from 'vitest';
import { paneWiring } from './pane-wiring';
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

function host(initial: string, primary: PaneDescriptor | null = null) {
  let url = new URL(initial, ORIGIN);
  const panes = () => dedupeSurfaces(primary, parsePanes(url.searchParams));
  const wiring = paneWiring({ url: () => url, panes, primary: () => primary });

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
    expect(h.panes()).toEqual([{ kind: 'files', mountKey: 'w3d', paths: ['CONTEXT.md'] }]);
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
    expect(h.panes()).toEqual([{ kind: 'files', mountKey: 'w3d', paths: ['CONTEXT.md'] }]);
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
    expect(h.panes()).toEqual([
      { kind: 'files', mountKey: 'life', paths: ['AGENTS.md', 'CONTEXT.md'] }
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
    h.context().openPane?.({ kind: 'files', mountKey: 'life', paths: ['CONTEXT.md'] });
    h.land();
    expect(h.panes()).toEqual([{ kind: 'files', mountKey: 'life', paths: ['CONTEXT.md'] }]);
    expect(h.context().takeAutoCreatedPath?.()).toBeNull();
  });
});
