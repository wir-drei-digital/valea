/**
 * Pure logic for editor link-click navigation and the dangling-link check
 * (Task C9). No I/O — the impure callers are `PageEditor.svelte` (click
 * handling + the dangling-decoration ProseMirror plugin) and the knowledge
 * route (`+page.svelte`, which feeds `collectDocLinkPaths`'s output to
 * `api.icmPathsExist` to build the dangling set).
 *
 * Mirrors `image-upload.ts`'s `joinRelative`/vocabulary conventions: every
 * resolved path is ICM-relative — mount identity rides `mountKey`, a value
 * passed alongside the path, never a leading `/` on the path string itself
 * (Fix-wave Finding 2, task-9.6-report.md, collapsed the older "leading
 * slash ⇒ external mount" reading here to match). A leading-slash `.md`
 * href in hand-authored content is read as ICM-ROOT-relative rather than
 * carrying any mount tag of its own.
 */

import { joinRelative } from './image-upload';

export type LinkClassification =
  | { kind: 'page'; path: string }
  | { kind: 'external'; url: string }
  | { kind: 'file' };

const HTTP_RE = /^https?:/i;
const MD_EXT_RE = /\.md$/i;

function dirnameOf(path: string): string {
  const idx = path.lastIndexOf('/');
  return idx === -1 ? '' : path.slice(0, idx);
}

/**
 * Classifies a stored `href` (a link mark's `attrs.href`, or an image
 * node's `attrs.src`) relative to `pagePath` — the page the href is
 * written on:
 *
 *  - `http(s):` → `external` (opened in a new tab, never intercepted as
 *    in-app navigation);
 *  - anything ending in `.md` → `page`, resolved to a concrete ICM-relative
 *    path: a leading-slash href is read as ICM-ROOT-relative (Fix-wave
 *    Finding 2, task-9.6-report.md — post-Phase-4, every in-ICM path is
 *    ICM-relative; mount identity rides `mountKey`, a value passed
 *    alongside the path, never a leading `/` on the path string itself, the
 *    same vocabulary `image-upload.ts`'s `resolveImageSrc`/`joinRelative`
 *    already use), so the leading slash(es) are stripped and the remainder
 *    resolved via the same lexical `joinRelative` math as any other
 *    relative href — just against the ICM root (`''`) instead of
 *    `pagePath`'s directory; an ordinary relative href is resolved against
 *    `pagePath`'s directory, same as C7's image extension;
 *  - everything else (a non-`.md` file reference, `mailto:`, a bare
 *    fragment, ...) → `file` — not something this app's editor can open,
 *    so link clicks on it are a deliberate no-op.
 */
export function classifyHref(href: string, pagePath: string): LinkClassification {
  if (HTTP_RE.test(href)) return { kind: 'external', url: href };

  if (MD_EXT_RE.test(href)) {
    const path = href.startsWith('/')
      ? joinRelative('', href.replace(/^\/+/, ''))
      : joinRelative(dirnameOf(pagePath), href);
    return { kind: 'page', path };
  }

  return { kind: 'file' };
}

type PMNode = {
  type?: unknown;
  attrs?: Record<string, unknown>;
  marks?: unknown[];
  content?: unknown[];
};

function hrefsOf(node: PMNode): string[] {
  const found: string[] = [];

  if (node.type === 'image') {
    const src = node.attrs?.src;
    if (typeof src === 'string') found.push(src);
  }

  if (Array.isArray(node.marks)) {
    for (const mark of node.marks) {
      if (!mark || typeof mark !== 'object') continue;
      const m = mark as PMNode;
      if (m.type === 'link') {
        const href = m.attrs?.href;
        if (typeof href === 'string') found.push(href);
      }
    }
  }

  return found;
}

/**
 * Walks a ProseMirror document JSON (a page's `content.prosemirror`, or
 * whatever the editor's `getJSON()` currently holds) collecting every
 * page-kind resolved path reachable from a link mark or image node's href.
 * Used by the route to build the payload for `api.icmPathsExist` — the
 * dangling-link check runs on page load and after each save. Deduped;
 * order is first-encountered (document order), not that it matters to the
 * caller.
 */
export function collectDocLinkPaths(docJson: unknown, pagePath: string): string[] {
  const found = new Set<string>();

  function walk(node: unknown): void {
    if (!node || typeof node !== 'object') return;
    const rec = node as PMNode;

    for (const href of hrefsOf(rec)) {
      const classification = classifyHref(href, pagePath);
      if (classification.kind === 'page') found.add(classification.path);
    }

    if (Array.isArray(rec.content)) {
      for (const child of rec.content) walk(child);
    }
  }

  walk(docJson);
  return [...found];
}
