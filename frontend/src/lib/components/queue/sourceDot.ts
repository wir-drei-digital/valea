/**
 * Source-dot semantics (docs/DESIGN_SYSTEM.md §2 "Source-dot semantics",
 * carried into §5/§6 "Source chips… dot color follows the source-dot
 * semantics"): the dot color on a source chip identifies the KIND of source,
 * not any state of the item it's attached to.
 *
 *   - Terracotta — email / external message  (`sources/mail/*`)
 *   - Green      — calendar / client memory   (`icm/Clients/*`)
 *   - Amber      — policy / offer / document  (everything else under `icm/`,
 *                  and — as the catch-all "document" bucket — anything that
 *                  isn't recognizably a mail or client-memory path)
 *
 * Sources arrive as free-text strings authored by the workflow's agent run
 * (`proposal/v1`'s `sources` array — see `Valea.Workflows.Runner`), so this
 * is a best-effort prefix match against the workspace-relative paths the
 * workflow contracts actually name, not a validated path type.
 */

export type SourceDotColor = 'terracotta' | 'green' | 'amber';

/** Tailwind utility class for the dot's background, keyed by color. */
export const SOURCE_DOT_CLASS: Record<SourceDotColor, string> = {
  terracotta: 'bg-warn-dot',
  green: 'bg-act-dot',
  amber: 'bg-suggest-dash'
};

export function sourceDot(path: string): SourceDotColor {
  if (path.startsWith('sources/mail/')) return 'terracotta';
  if (path.startsWith('icm/Clients/')) return 'green';
  return 'amber';
}

/**
 * Knowledge-page href for a source chip, or `null` when the source isn't a
 * page this phase can link to. Only `icm/*.md` paths resolve to a Knowledge
 * route; `sources/mail/*` and anything else render as an inert chip (same
 * "show the path, link opens nothing this phase" stance the invalid
 * queue-item card takes — there is no raw-file viewer yet).
 *
 * Sources arrive as WORKSPACE-relative paths (workflow contracts and
 * `proposal/v1.sources` both name pages as `icm/Offers/...` — see
 * `Valea.Workflows.Runner`'s prompt and any workflow's YAML `sources:`
 * list), but the Knowledge route's paths are relative to the `icm/` root
 * itself and never carry that prefix (`Valea.ICM.tree/0` computes each
 * node's `path` via `Path.relative_to(abs, Path.join(workspace, "icm"))` —
 * confirmed against `icmToNav`'s `/knowledge/${encodePath(n.path)}` in
 * `frontend/src/lib/shell/nav.ts`, which a sidebar page link actually
 * resolves to, e.g. `/knowledge/Offers/Founder%20Coaching%20Package.md`,
 * NOT `/knowledge/icm/Offers/...`). The `icm/` prefix is stripped here
 * before building the href so a source chip lands on the same URL the
 * sidebar would.
 */
export function sourceHref(path: string): string | null {
  if (!path.startsWith('icm/') || !path.endsWith('.md')) return null;
  const relative = path.slice('icm/'.length);
  return `/knowledge/${relative.split('/').map(encodeURIComponent).join('/')}`;
}
