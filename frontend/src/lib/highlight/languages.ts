/**
 * Filename / fence-info → highlight.js grammar id. Pure, and the ONLY place
 * the mapping lives: the file viewer asks by filename and the chat renderer
 * asks by fence, and the two must agree about what `.ex` is.
 *
 * `null` means "render plain" — never a guess. An unmapped extension is a
 * missing entry here, not a bug in a viewer.
 *
 * `GRAMMARS` is the canonical id list. `highlight.ts` builds its loader map
 * from it and a test there fails if the two ever disagree, so adding a
 * language is: one id here, one extension row, one loader there.
 */

export const GRAMMARS = [
  'bash', 'c', 'cpp', 'csharp', 'css', 'diff', 'dockerfile', 'elixir', 'go',
  'ini', 'java', 'javascript', 'json', 'kotlin', 'makefile', 'markdown',
  'php', 'python', 'ruby', 'rust', 'scss', 'sql', 'swift', 'typescript',
  'xml', 'yaml'
] as const;

export type Grammar = (typeof GRAMMARS)[number];

const GRAMMAR_SET: ReadonlySet<string> = new Set(GRAMMARS);

export function isGrammar(value: string): value is Grammar {
  return GRAMMAR_SET.has(value);
}

/**
 * Extension (no dot, lowercased) → grammar.
 *
 * Deliberate approximations, recorded so nobody later reads them as bugs:
 * `.svelte`/`.vue` are highlighted as `xml`, which gets tags and attributes
 * right and expression interpolation wrong; `.heex`/`.eex` as `elixir`, which
 * gets the embedded expressions right and the surrounding markup wrong;
 * `Justfile` as `makefile`, which is close enough to read; `.toml` as `ini`,
 * which highlight.js does not ship a separate grammar for.
 */
const BY_EXTENSION: Record<string, Grammar> = {
  bash: 'bash', sh: 'bash', zsh: 'bash', fish: 'bash',
  c: 'c', h: 'c',
  cc: 'cpp', cpp: 'cpp', hpp: 'cpp',
  cs: 'csharp',
  css: 'css',
  diff: 'diff', patch: 'diff',
  ex: 'elixir', exs: 'elixir', eex: 'elixir', heex: 'elixir',
  go: 'go',
  ini: 'ini', toml: 'ini',
  java: 'java',
  cjs: 'javascript', js: 'javascript', jsx: 'javascript', mjs: 'javascript',
  json: 'json',
  kt: 'kotlin',
  md: 'markdown', markdown: 'markdown',
  php: 'php',
  py: 'python',
  rb: 'ruby',
  rs: 'rust',
  scss: 'scss',
  sql: 'sql',
  swift: 'swift',
  cts: 'typescript', mts: 'typescript', ts: 'typescript', tsx: 'typescript',
  htm: 'xml', html: 'xml', svelte: 'xml', svg: 'xml', vue: 'xml', xml: 'xml',
  yaml: 'yaml', yml: 'yaml'
};

/** Whole-basename matches, for the files that carry their type in their name. */
const BY_BASENAME: Record<string, Grammar> = {
  dockerfile: 'dockerfile',
  justfile: 'makefile',
  makefile: 'makefile'
};

/** Fence words that are neither a grammar id nor an extension. */
const FENCE_ALIASES: Record<string, Grammar> = {
  console: 'bash',
  shell: 'bash',
  yml: 'yaml'
};

export function grammarForFilename(name: string): Grammar | null {
  const base = (name.split('/').pop() ?? '').toLowerCase();
  if (!base) return null;

  const byName = BY_BASENAME[base];
  if (byName) return byName;

  // `> 0`, not `>= 0`: a leading dot is a dotfile (`.gitignore`), not an
  // extension — the same test `FileView` uses to derive `ext`.
  const dot = base.lastIndexOf('.');
  if (dot <= 0) return null;

  return BY_EXTENSION[base.slice(dot + 1)] ?? null;
}

export function grammarForFence(info: string): Grammar | null {
  const first = info.trim().split(/\s+/)[0]?.toLowerCase() ?? '';
  if (!first) return null;
  if (isGrammar(first)) return first;
  return FENCE_ALIASES[first] ?? BY_EXTENSION[first] ?? null;
}
