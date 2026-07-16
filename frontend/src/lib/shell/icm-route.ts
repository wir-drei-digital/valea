/**
 * Pure route-resolution logic for the Phase 9 `?icm=<mount-key>` /
 * `?session=<session-id>` scheme (Task 9.4) — formalizes what was previously
 * partial, inline logic in `/chat`'s `primaryMountKey()`. Same
 * "extract the logic, no component render harness" convention as
 * `nav.ts`/`mount-sections.ts`.
 *
 * The rule, stated once here rather than re-derived per route:
 *  - `?session=<id>` is AUTHORITATIVE for an existing transcript — its own
 *    metadata determines the ICM, and `?icm=` is never consulted to
 *    "reassign" it. Structurally true on `/chat` without any resolution
 *    function needed: `selectedId`/the joined `AgentSessionStore` are
 *    derived from `?session=` alone (see `routes/chat/+page.svelte`) — this
 *    module's `resolveActiveMountKey` below covers the one place that DOES
 *    need to resolve a session id BACK to an ICM (the sidebar's
 *    highlighting).
 *  - `?icm=<key>` only ever SELECTS an ICM for a new-session/empty-state
 *    context (chat's "Start a session"/"New session", Knowledge's tree pane
 *    with no path pinning it) — falling back to the first enabled mount
 *    (config order) when absent, and NEVER gated by whatever `?session=`
 *    happens to also be in the URL (`resolveIcmSelection` below takes no
 *    session parameter at all — starting a new session is independent of
 *    whatever transcript is currently open).
 */

/**
 * Resolves a "new selection" context's ICM: `icmParam` when present
 * (verbatim — validity, e.g. a disabled/degraded/unknown key, is the
 * caller's problem to render an empty/error state for, not this function's),
 * otherwise the first enabled mount in config order. `null` when neither is
 * available (no ICM mounted/enabled yet).
 */
export function resolveIcmSelection(icmParam: string | null, enabledMountKeys: string[]): string | null {
  return icmParam ?? enabledMountKeys[0] ?? null;
}

/**
 * Derives which ICM the sidebar (`IcmProjects.svelte`'s `activeMountKey`
 * prop) should treat as "the one the current route is scoped to":
 *  - `/knowledge/<mountKey>/...` (Task 4.3's path-based deep link) — the
 *    mount key rides the PATH, not `?icm=` (ambiguity resolution: "the path
 *    wins for the open page, and the tree follows the page's mount").
 *  - `/chat?session=<id>` — looked up via `recentGroups` (the only place the
 *    frontend currently knows a session's owning ICM; there is no per-session
 *    `mountKey` field on `AgentSessionSummary` — see
 *    `recent-sessions.svelte.ts`'s header doc). A session outside every
 *    group's recent-session cap (or not yet loaded) resolves to `null` —
 *    the sidebar simply doesn't force that group open, a known,
 *    non-fatal gap rather than a bug. `?icm=` is deliberately NOT
 *    consulted as a fallback here either, same "session is authoritative,
 *    icm is never a reassignment" rule this module's header doc states.
 *  - Every other route (`/knowledge` with no path, `/chat` with no session,
 *    and any future ICM-scoped route) reads `?icm=` directly.
 */
export function resolveActiveMountKey(
  pathname: string,
  searchParams: URLSearchParams,
  recentGroups: { mountKey: string; sessions: { id: string }[] }[]
): string | null {
  const knowledgePathMatch = /^\/knowledge\/([^/]+)(?:\/|$)/.exec(pathname);
  if (knowledgePathMatch) {
    return decodeURIComponent(knowledgePathMatch[1]);
  }

  if (pathname.startsWith('/chat')) {
    const sessionId = searchParams.get('session');
    if (sessionId) {
      const owner = recentGroups.find((g) => g.sessions.some((s) => s.id === sessionId));
      return owner?.mountKey ?? null;
    }
  }

  return searchParams.get('icm');
}

/** Filters a `{mountKey}`-carrying list down to one mount when `mountKey` is given; passes everything through when it's `null` (no filter selected). */
export function filterByMountKey<T extends { mountKey: string }>(items: T[], mountKey: string | null): T[] {
  return mountKey ? items.filter((item) => item.mountKey === mountKey) : items;
}
