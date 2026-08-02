/**
 * Every folder href above a file, outermost first — what `treeOpenState.open()`
 * needs to reveal a file's ancestors. Lifted out of
 * `routes/knowledge/[...path]/+page.svelte`, where it was inlined and so
 * unavailable to any other pane host.
 */
import { knowledgeHref } from './nav';

export function ancestorHrefs(mountKey: string, path: string): string[] {
  if (!path) return [];
  const segments = path.split('/');
  const hrefs: string[] = [];
  for (let i = 0; i < segments.length - 1; i++) {
    hrefs.push(knowledgeHref(mountKey, segments.slice(0, i + 1).join('/')));
  }
  return hrefs;
}

/**
 * The gate that makes a reveal fire on NAVIGATION rather than on every run of
 * the effect it sits in (issue #4).
 *
 * Revealing is a one-shot courtesy: landing on `life/A/B/doc.md` should show
 * where that document lives. It is NOT a standing rule that A and B are open —
 * once the user collapses them, they must stay collapsed. But the effect doing
 * the revealing reads more than the path: the route reads `isFolder`, which
 * comes from the lazy ICM tree, so every `icm_changed` refetch re-runs it. Left
 * ungated it re-opens folders the user closed, which is the reported bug
 * arriving by a second route.
 *
 * Deliberately NOT reactive: `#last` is a plain field, so recording a reveal
 * never invalidates the effect that recorded it.
 */
export class RevealOnce {
  #last: string | null = null;

  /** True once per distinct `key`, false while it stays the same. */
  changed(key: string): boolean {
    if (key === this.#last) return false;
    this.#last = key;
    return true;
  }
}
