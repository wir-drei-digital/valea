import { describe, it, expect } from 'vitest';
import { sessionCreateOpts } from './session-create-opts';

// Spec 2026-08-02 §"one creation site that knows the origin". Two independent
// obligations live in this one function:
//
//  1. The hyphen→underscore WIRE MAPPING. Comparatively safe on its own — the
//     create action allowlists exactly three underscored values server-side,
//     so a wrong kind fails closed rather than mislabelling a session.
//  2. The REFUSAL for a `page`/`file` origin whose ICM has no loadable id.
//     Nothing downstream catches this one: dropping `from` and creating the
//     session anyway yields a session that looks normal while being silently
//     detached from what it was opened from — the exact bug this feature
//     exists to prevent. It is asserted here so a "simplify the guard" edit
//     goes red instead of shipping.
describe('sessionCreateOpts', () => {
  describe('the wire spelling of the origin kind', () => {
    it('sends a mail-message origin as mail_message', () => {
      const outcome = sessionCreateOpts({
        from: { kind: 'mail-message', path: 'sources/mail/mara/views/messages/42.md' },
        icmId: undefined
      });

      expect(outcome).toEqual({
        ok: true,
        opts: {
          input: { kind: 'workspace', path: 'sources/mail/mara/views/messages/42.md' },
          includeMounts: [],
          openedFromKind: 'mail_message'
        }
      });
    });

    it('sends a page origin as page, against the ICM locator', () => {
      const outcome = sessionCreateOpts({
        from: { kind: 'page', path: 'CONTEXT.md' },
        icmId: 'icm-1'
      });

      expect(outcome).toEqual({
        ok: true,
        opts: {
          contextDoc: { kind: 'icm', icm_id: 'icm-1', path: 'CONTEXT.md' },
          openedFromKind: 'page'
        }
      });
    });

    it('sends a file origin as file, against the ICM locator', () => {
      const outcome = sessionCreateOpts({
        from: { kind: 'file', path: 'notes/invoice.pdf' },
        icmId: 'icm-1'
      });

      expect(outcome).toEqual({
        ok: true,
        opts: {
          contextDoc: { kind: 'icm', icm_id: 'icm-1', path: 'notes/invoice.pdf' },
          openedFromKind: 'file'
        }
      });
    });
  });

  describe('a page/file origin whose ICM has no loadable id', () => {
    // THE UNGUARDED HALF. Creating the session without `from` would look like
    // success to the user and to the sessions list.
    it('REFUSES a page origin rather than creating a detached session', () => {
      expect(sessionCreateOpts({ from: { kind: 'page', path: 'CONTEXT.md' }, icmId: undefined })).toEqual(
        { ok: false, reason: 'icm-identity-missing' }
      );
    });

    it('REFUSES a file origin rather than creating a detached session', () => {
      expect(
        sessionCreateOpts({ from: { kind: 'file', path: 'notes/invoice.pdf' }, icmId: undefined })
      ).toEqual({ ok: false, reason: 'icm-identity-missing' });
    });

    // `MountSummary.id` is nullable, so a degraded mount reaches this as
    // `null` while a mount missing from the catalog reaches it as `undefined`.
    // Both mean "no loadable identity" and both must refuse.
    it('REFUSES a null id, the shape a degraded mount actually arrives in', () => {
      expect(sessionCreateOpts({ from: { kind: 'page', path: 'CONTEXT.md' }, icmId: null })).toEqual({
        ok: false,
        reason: 'icm-identity-missing'
      });
    });

    it('refuses an empty-string id too — it is no more loadable than an absent one', () => {
      expect(sessionCreateOpts({ from: { kind: 'page', path: 'CONTEXT.md' }, icmId: '' })).toEqual({
        ok: false,
        reason: 'icm-identity-missing'
      });
    });

    it('never refuses a mail-message origin — it needs no ICM id at all', () => {
      const outcome = sessionCreateOpts({
        from: { kind: 'mail-message', path: 'sources/mail/mara/views/messages/42.md' },
        icmId: undefined
      });

      expect(outcome.ok).toBe(true);
    });
  });

  describe('the mail mount', () => {
    it('includes the origin mount when it has one', () => {
      const outcome = sessionCreateOpts({
        from: {
          kind: 'mail-message',
          path: 'sources/mail/mara/views/messages/42.md',
          mount: 'mail-mara'
        },
        icmId: undefined
      });

      expect(outcome).toEqual({
        ok: true,
        opts: {
          input: { kind: 'workspace', path: 'sources/mail/mara/views/messages/42.md' },
          includeMounts: ['mail-mara'],
          openedFromKind: 'mail_message'
        }
      });
    });

    // `mount` is optional on `PaneOrigin`, so a link without one must widen
    // the session's scope by NOTHING — never by `[undefined]`, which the
    // action would reject, and never by a guessed mount key.
    it('grants no extra mount when the origin has none', () => {
      const outcome = sessionCreateOpts({
        from: { kind: 'mail-message', path: 'sources/mail/mara/views/messages/42.md' },
        icmId: undefined
      });

      expect(outcome).toEqual({
        ok: true,
        opts: expect.objectContaining({ includeMounts: [] })
      });
    });
  });

  it('asks for no options at all when the composer has no origin', () => {
    expect(sessionCreateOpts({ from: null, icmId: 'icm-1' })).toEqual({ ok: true, opts: undefined });
  });

  // The label is untrusted URL text (`PaneOrigin.label`) and display-only:
  // every grant is derived from `path`, so nothing the label says can reach
  // the wire.
  it('never derives a grant from the untrusted label', () => {
    const outcome = sessionCreateOpts({
      from: { kind: 'page', path: 'CONTEXT.md', label: '../../etc/passwd' },
      icmId: 'icm-1'
    });

    expect(JSON.stringify(outcome)).not.toContain('passwd');
  });
});
