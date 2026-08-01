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
