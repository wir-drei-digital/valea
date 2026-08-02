import type { PaneOrigin } from '$lib/panes/pane-route';

// The descriptor's origin kind is HYPHENATED (`PaneOrigin['kind']`); the
// create action's wire spelling is UNDERSCORED and allowlisted server-side to
// exactly these three values — anything else fails the action closed. This
// table is the one place the two spellings meet. It is deliberately a TOTAL
// `Record` over `PaneOrigin['kind']`: a fourth origin kind breaks this file's
// build instead of silently shipping a value the backend rejects at runtime.
const WIRE_ORIGIN_KIND: Record<PaneOrigin['kind'], 'mail_message' | 'page' | 'file'> = {
  'mail-message': 'mail_message',
  page: 'page',
  file: 'file'
};

/** The `opts` half of `api.createAgentSession` — structurally, not by import. */
export type SessionCreateOpts = {
  contextDoc?: { kind: 'icm'; icm_id: string; path: string };
  input?: { kind: 'workspace'; path: string };
  includeMounts?: string[];
  openedFromKind: 'mail_message' | 'page' | 'file';
};

/**
 * `opts: undefined` means "create a plain session" — the only case with no
 * origin at all. A refusal is NOT an absent origin: see below.
 */
export type SessionCreateOptsOutcome =
  | { ok: true; opts: SessionCreateOpts | undefined }
  | { ok: false; reason: 'icm-identity-missing' };

/**
 * The backend create options a new-session composer's origin descriptor asks
 * for (spec 2026-08-02). Extracted from `ChatView.createAndPrompt` so the
 * refusal branch below is testable — the component keeps the mount lookup and
 * the error copy.
 *
 * PARSED IS NOT RESOLVABLE. The pane codec validates the origin's SHAPE only —
 * a well-formed URL can still name a mount whose manifest has no loadable id
 * (degraded, unmounted since, hand-written link). A `page`/`file` origin needs
 * that id to build its ICM locator, so when it is missing this REFUSES rather
 * than returning options. Silently dropping `from` and creating a blank
 * session would produce a session that looks normal while being detached from
 * what it was opened from — the exact bug this feature exists to prevent. A
 * `mail-message` origin needs no ICM id (it carries a workspace-relative
 * locator plus its own mail mount), so it is exempt from the refusal and
 * ignores `icmId` entirely.
 *
 * The grant is derived from `from.path` — NEVER from `from.label`, which is
 * untrusted URL text and display-only (see `PaneOrigin`).
 */
export function sessionCreateOpts(args: {
  from: PaneOrigin | null;
  /**
   * The primary ICM's manifest id. Nullish when the mount is degraded, has
   * been unmounted since, or is not in the catalog at all — `MountSummary.id`
   * is itself nullable, so all three shapes reach here and mean the same
   * thing: no loadable identity.
   */
  icmId: string | null | undefined;
}): SessionCreateOptsOutcome {
  const { from, icmId } = args;
  if (from === null) return { ok: true, opts: undefined };

  if (from.kind === 'mail-message') {
    return {
      ok: true,
      opts: {
        input: { kind: 'workspace', path: from.path },
        includeMounts: from.mount ? [from.mount] : [],
        openedFromKind: WIRE_ORIGIN_KIND[from.kind]
      }
    };
  }

  if (!icmId) return { ok: false, reason: 'icm-identity-missing' };

  return {
    ok: true,
    opts: {
      contextDoc: { kind: 'icm', icm_id: icmId, path: from.path },
      openedFromKind: WIRE_ORIGIN_KIND[from.kind]
    }
  };
}
