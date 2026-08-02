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
  const css = readFileSync(CSS_PATH, 'utf8');
  const selector = palette === 'light' ? ':root' : '.dark';
  const start = css.indexOf(`${selector} {`);
  if (start === -1) return {};

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
