import { describe, expect, it } from 'vitest';
import {
  CAP_REFUSAL,
  WIDTH_REFUSAL,
  alreadyOpenRefusal,
  paneRefusal,
  roomRefusal
} from './pane-offer';
import { PANE_CAP } from './pane-route';

describe('roomRefusal', () => {
  it('allows an open when the row is under the cap and the width has a slot', () => {
    expect(roomRefusal(0, 2)).toBeNull();
    expect(roomRefusal(1, 2)).toBeNull();
  });

  it('refuses at the cap, naming the cap', () => {
    expect(roomRefusal(PANE_CAP, 5)).toBe(CAP_REFUSAL);
  });

  it('refuses when the window has no slot left, naming the width', () => {
    expect(roomRefusal(1, 1)).toBe(WIDTH_REFUSAL);
    expect(roomRefusal(0, 0)).toBe(WIDTH_REFUSAL);
  });

  it('reports the cap rather than the width when both are exceeded', () => {
    // The cap outranks the width because it is the refusal no monitor lifts:
    // "buy a wider screen" is false advice at the cap.
    expect(roomRefusal(PANE_CAP, 0)).toBe(CAP_REFUSAL);
  });

  it('refuses while the window is unmeasured, rather than guessing a yes', () => {
    // `paneRoom.slots` is 0 before the first measurement and on the server.
    expect(roomRefusal(0, 0)).toBe(WIDTH_REFUSAL);
  });
});

describe('paneRefusal', () => {
  const room = { open: 0, slots: 2 };

  it('allows a kind that is not on screen', () => {
    expect(paneRefusal({ ...room, openKinds: ['mail'], wanted: 'chat' })).toBeNull();
  });

  it('refuses a kind the route’s own primary is already showing', () => {
    // `openKinds` carries the primary, because `dedupeSurfaces` counts it —
    // without this the control appears to work and the URL silently drops the
    // pane it asked for.
    expect(paneRefusal({ ...room, openKinds: ['files'], wanted: 'files' })).toBe(
      alreadyOpenRefusal('files')
    );
  });

  it('refuses a kind another side pane is already showing', () => {
    expect(paneRefusal({ open: 1, slots: 2, openKinds: ['mail', 'chat'], wanted: 'chat' })).toBe(
      alreadyOpenRefusal('chat')
    );
  });

  it('reports "already open" ahead of the cap and the width', () => {
    expect(
      paneRefusal({ open: PANE_CAP, slots: 0, openKinds: ['files'], wanted: 'files' })
    ).toBe(alreadyOpenRefusal('files'));
  });

  it('falls through to the room refusal when the kind is free', () => {
    expect(paneRefusal({ open: PANE_CAP, slots: 9, openKinds: [], wanted: 'files' })).toBe(
      CAP_REFUSAL
    );
    expect(paneRefusal({ open: 1, slots: 1, openKinds: [], wanted: 'files' })).toBe(WIDTH_REFUSAL);
  });

  it('keeps chat-new legal beside chat, the way dedupeSurfaces does', () => {
    // `dedupeSurfaces` compares raw kinds, so a new-session pane may sit beside
    // an open session. Folding the two together here would refuse an open the
    // URL accepts.
    expect(paneRefusal({ open: 1, slots: 2, openKinds: ['chat'], wanted: 'chat-new' })).toBeNull();
    expect(paneRefusal({ open: 1, slots: 2, openKinds: ['chat-new'], wanted: 'chat' })).toBeNull();
  });
});

describe('alreadyOpenRefusal', () => {
  it('names the surface for every kind, and never returns an empty reason', () => {
    // A refusal with nothing to say is the silent no-op wearing a disabled
    // attribute — every branch has to carry words.
    for (const kind of ['files', 'chat', 'chat-new', 'mail'] as const) {
      expect(alreadyOpenRefusal(kind).length).toBeGreaterThan(0);
    }
    expect(alreadyOpenRefusal('files')).toContain('file browser');
    expect(alreadyOpenRefusal('chat')).toContain('session');
    expect(alreadyOpenRefusal('chat-new')).toContain('new session');
    expect(alreadyOpenRefusal('mail')).toContain('Mail');
  });
});
