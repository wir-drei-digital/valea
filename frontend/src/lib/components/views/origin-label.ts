import type { PaneOrigin } from '$lib/panes/pane-route';

/**
 * What the new-session composer's attachment chip says — the whole visible
 * evidence that the composer is pointed at a source, now that the entry points
 * no longer send a canned first turn (spec 2026-08-02).
 *
 * `label` → path basename → whole path, and `null` when none of the three is
 * displayable. `||` and `.trim()` at every step, not `??`: the chain must not
 * be able to produce a BLANK chip. `parseOrigin` only rejects a FALSY label, so
 * a whitespace-only one survives it; and a hand-written trailing-slash path
 * (`mail-message/INBOX%2F`) makes the basename `''`. Neither is nullish, so
 * `??` would hand the chip an empty string and render an icon with nothing
 * beside it. `null` means nothing is displayable — then no chip renders at
 * all, which is honest, where a blank one is just broken. The guarantee is
 * exactly that and no more: a degenerate path with no usable segment (`'///'`)
 * lands on the last rung and shows verbatim rather than vanishing.
 *
 * SECURITY: `label` is URL-supplied and untrusted. It is display-only — every
 * grant comes from `path` (see `sessionCreateOpts`) — it is capped at
 * `ORIGIN_LABEL_CAP` by the parser, and it reaches the DOM only through plain
 * interpolation. Never `{@html}`.
 */
export function originLabel(from: PaneOrigin | null): string | null {
  if (!from) return null;
  // Dropping empty segments makes "INBOX/" read as "INBOX" rather than falling
  // through to the full path — a basename is what a human can use.
  const segments = from.path
    .split('/')
    .map((s) => s.trim())
    .filter(Boolean);
  return from.label?.trim() || segments[segments.length - 1] || from.path.trim() || null;
}

/**
 * The mount the chip must NAME beside its label, or `null` when the origin
 * carries none.
 *
 * SECURITY VISIBILITY, not decoration. On the mail path `from.mount` becomes
 * `includeMounts` — the session is scoped into a WHOLE mail account: every
 * read view, plus writes to `ops/` and `drafts/`. The backend only accepts a
 * key that names an already-enabled mount, so no new capability is minted
 * here; what a link CAN do is scope a session into a different account than
 * the subject line suggests, and a chip that showed only `label` gave the
 * user nothing to notice that with. The grant is the mount, so the mount is
 * what has to be on screen.
 *
 * Shown VERBATIM (`mail-mara`, not a prettified "mara"): the point is to
 * match what was granted, and two mounts that differ only in a prefix must
 * not render identically. Untrusted like `label` — plain interpolation only,
 * never `{@html}` — and truncated by CSS rather than by string surgery, so a
 * long key shortens on screen without a shortened key ever reading as a
 * different, real one.
 */
export function originMount(from: PaneOrigin | null): string | null {
  return from?.mount?.trim() || null;
}
