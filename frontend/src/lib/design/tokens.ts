/**
 * Reads the raw colour tokens straight out of `layout.css` so palette tests
 * fail when the PALETTE changes, not when a duplicated copy of it drifts.
 *
 * Only literal hex values are returned. Tokens defined as `var(...)`
 * indirections (the shadcn semantic mapping) are skipped: what the
 * invariants are about is the raw paper/ink/consequence ramps.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const CSS_PATH = fileURLToPath(new URL('../../routes/layout.css', import.meta.url));

export type Palette = 'light' | 'dark';

/**
 * `:root { ... }` holds the light palette; `.dark { ... }` holds dark.
 * Returns `{}` when the requested block does not exist yet.
 */
export function readPalette(palette: Palette): Record<string, string> {
  // Strip comments BEFORE searching. A prose mention of the selector followed
  // by a brace — e.g. describing "the `.dark { ... }` block" in a comment —
  // otherwise wins the search, and the walk below then reads a comment body
  // and returns {}, which makes every palette invariant pass vacuously.
  const css = readFileSync(CSS_PATH, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');

  // Anchored to the start of a line, so `html.dark {` in `@layer base` cannot
  // match either — the old substring search only avoided it by accident of
  // source order.
  const selector = palette === 'light' ? ':root' : '\\.dark';
  const m = new RegExp(`^\\s*${selector}\\s*\\{`, 'm').exec(css);
  if (!m) return {};
  const start = m.index;

  // Walk braces from the selector so nested blocks cannot end it early.
  let depth = 0;
  let end = start;
  for (let i = css.indexOf('{', start); i < css.length; i++) {
    if (css[i] === '{') depth++;
    else if (css[i] === '}' && --depth === 0) {
      end = i;
      break;
    }
  }

  const body = css.slice(start, end);
  const out: Record<string, string> = {};
  for (const [, name, value] of body.matchAll(/--([a-z0-9-]+):\s*(#[0-9a-fA-F]{3,8})\s*;/g)) {
    out[name] = value.toLowerCase();
  }
  return out;
}
