/**
 * Syntax highlighting, as DATA.
 *
 * `lowlight` is the highlight.js engine wrapped to return a hast tree
 * (`{type, tagName, properties.className, children}`) instead of an HTML
 * string. That is the whole reason it is here rather than highlight.js
 * directly: an HTML string would have to reach the DOM through `{@html}`,
 * which is forbidden in the families that render agent output and file bytes
 * alike. `HastNode.svelte` walks this tree into real elements instead.
 *
 * Grammars load lazily, one chunk each. The loader map's specifiers are
 * LITERAL — a template-literal `import()` would defeat Vite's code splitting
 * and pull every grammar into the main bundle.
 *
 * Highlighting is an enhancement, never a dependency: a grammar that fails to
 * load and a tokeniser that throws both answer `null`, and every caller
 * renders plain text for `null`.
 */
import { createLowlight } from 'lowlight';
import type { Root } from 'hast';
import type { Grammar } from './languages';

/**
 * Characters, not bytes — `String.length` is what we have and what the
 * tokeniser's cost tracks. The viewer already caps its READ at 500 KB
 * (`capped-text.ts`); this caps the far more expensive tokenise, because
 * highlighting a half-megabyte file blocks the main thread long enough to
 * read as a hang.
 */
export const MAX_HIGHLIGHT_CHARS = 200_000;

const lowlight = createLowlight();

type Loader = () => Promise<{ default: Parameters<typeof lowlight.register>[1] }>;

const LOADERS: Record<Grammar, Loader> = {
  bash: () => import('highlight.js/lib/languages/bash'),
  c: () => import('highlight.js/lib/languages/c'),
  cpp: () => import('highlight.js/lib/languages/cpp'),
  csharp: () => import('highlight.js/lib/languages/csharp'),
  css: () => import('highlight.js/lib/languages/css'),
  diff: () => import('highlight.js/lib/languages/diff'),
  dockerfile: () => import('highlight.js/lib/languages/dockerfile'),
  elixir: () => import('highlight.js/lib/languages/elixir'),
  go: () => import('highlight.js/lib/languages/go'),
  ini: () => import('highlight.js/lib/languages/ini'),
  java: () => import('highlight.js/lib/languages/java'),
  javascript: () => import('highlight.js/lib/languages/javascript'),
  json: () => import('highlight.js/lib/languages/json'),
  kotlin: () => import('highlight.js/lib/languages/kotlin'),
  makefile: () => import('highlight.js/lib/languages/makefile'),
  markdown: () => import('highlight.js/lib/languages/markdown'),
  php: () => import('highlight.js/lib/languages/php'),
  python: () => import('highlight.js/lib/languages/python'),
  ruby: () => import('highlight.js/lib/languages/ruby'),
  rust: () => import('highlight.js/lib/languages/rust'),
  scss: () => import('highlight.js/lib/languages/scss'),
  sql: () => import('highlight.js/lib/languages/sql'),
  swift: () => import('highlight.js/lib/languages/swift'),
  typescript: () => import('highlight.js/lib/languages/typescript'),
  xml: () => import('highlight.js/lib/languages/xml'),
  yaml: () => import('highlight.js/lib/languages/yaml')
};

/** grammar -> the one in-flight (then settled) load. Keyed so a grammar loads once per app lifetime. */
const loads = new Map<Grammar, Promise<boolean>>();

function ensure(grammar: Grammar): Promise<boolean> {
  const existing = loads.get(grammar);
  if (existing) return existing;

  const load = LOADERS[grammar]()
    .then((module) => {
      if (!lowlight.registered(grammar)) lowlight.register(grammar, module.default);
      return true;
    })
    .catch(() => false);

  loads.set(grammar, load);
  return load;
}

export async function highlight(code: string, grammar: Grammar | null): Promise<Root | null> {
  if (grammar === null) return null;
  if (code.length > MAX_HIGHLIGHT_CHARS) return null;
  if (!(await ensure(grammar))) return null;

  try {
    return lowlight.highlight(grammar, code);
  } catch {
    return null;
  }
}
