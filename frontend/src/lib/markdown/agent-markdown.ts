import { Lexer, type Token } from 'marked';

/**
 * Markdown support for AGENT-AUTHORED chat messages, built so the agent/
 * component family's standing security rule survives intact: `{@html}`
 * stays forbidden. We never render markdown → HTML string. Instead the
 * message is lexed into marked's token TREE here, and
 * `MarkdownBlocks.svelte`/`MarkdownInline.svelte` walk that tree emitting
 * real elements whose text reaches the DOM only through plain Svelte
 * interpolation (auto-escaped). Raw `html` tokens are rendered AS TEXT,
 * links only get an `<a>` for vetted schemes, images never fetch.
 */
export type { Token };

/**
 * `breaks: true` — chat messages treat a single newline as a line break
 * (models often emit one-per-line enumerations that would otherwise
 * collapse into a single run-on paragraph).
 */
export function lexAgentMarkdown(text: string): Token[] {
  return Lexer.lex(text, { gfm: true, breaks: true });
}

/**
 * The only URL schemes that become a real link. Anything else (javascript:,
 * data:, vbscript:, file:, unknown relative forms…) renders as plain text —
 * an agent-authored destination is untrusted input.
 */
export function safeLinkHref(href: string | null | undefined): string | null {
  if (!href) return null;
  const trimmed = href.trim();
  if (/^https?:\/\//i.test(trimmed) || /^mailto:/i.test(trimmed)) return trimmed;
  return null;
}

/**
 * marked's inline lexer pre-escapes SOME token text (codespans always;
 * text tokens when flagged `escaped`). Svelte interpolation escapes again
 * at render time, so without this the user would literally see `&amp;`.
 * Only the five entities marked's own `escape()` produces are reversed —
 * this is not a general HTML decoder.
 */
export function unescapeMarked(text: string): string {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

// Basename must END in a letter-led extension, and the match must not start
// at index 0 (bare ".md" or ".gitignore" is not a stem + extension —
// documented accepted miss).
const EXTENSION_RE = /\.[A-Za-z][A-Za-z0-9]{0,7}$/;

/**
 * The openable ICM-relative path of a codespan, or undefined. Input is the
 * DECODED codespan text (marked pre-escapes codespans — callers pass it
 * through `unescapeMarked` first, so what opens is exactly what displays).
 * One trailing `:NN` line suffix is stripped (`CONTEXT.md:22`). Anything
 * absolute, traversal-y, directory-like, scheme-ish, or not ending in a
 * letter-led extension is rejected; spaces are allowed only when a `/` is
 * present (`clients/Mara Lindt/notes.md`), so a backticked sentence never
 * qualifies. The returned string is untrusted agent output — callers hand
 * it ONLY to the `?pane=` codec / backend-validated APIs.
 */
export function codespanFilePath(text: string): string | undefined {
  if (!text || text.length > 256) return undefined;
  const stripped = text.replace(/:\d+$/, '');
  if (!stripped || stripped.includes(':')) return undefined; // scheme, drive, second :NN
  if (stripped.startsWith('/') || stripped.startsWith('~')) return undefined;
  if (stripped.endsWith('/')) return undefined;
  if (/[`()\\]/.test(stripped)) return undefined;
  for (let i = 0; i < stripped.length; i++) {
    const code = stripped.charCodeAt(i);
    if (code < 32 || code === 127) return undefined; // control chars incl. tab/newline
  }
  if (stripped.includes(' ') && !stripped.includes('/')) return undefined;
  const segments = stripped.split('/');
  if (segments.some((seg) => seg === '' || seg === '.' || seg === '..')) return undefined;
  const basename = segments[segments.length - 1];
  const ext = EXTENSION_RE.exec(basename);
  if (!ext || ext.index === 0) return undefined;
  return stripped;
}

/**
 * Distinct `codespanFilePath` hits across a whole agent message — the
 * auto-open candidate set. Walks the lexed token tree through every inline
 * container (emphasis, links, list items, table cells) but never descends
 * into fenced `code` blocks; codespan text is decoded before detection.
 * The walk descends into `link` subtrees even though the renderer suppresses
 * interactive codespans inside links — deliberate: the extra candidate can
 * only suppress auto-open (count > 1) or itself pass the existence gate,
 * never open something that was made unclickable for safety reasons.
 */
export function messageFilePaths(text: string): string[] {
  if (!text) return [];
  const seen = new Set<string>();
  type Walkable = Token & {
    text?: string;
    tokens?: Token[];
    items?: Array<{ tokens?: Token[] }>;
    header?: Array<{ tokens?: Token[] }>;
    rows?: Array<Array<{ tokens?: Token[] }>>;
  };
  const walk = (tokens: Token[]): void => {
    for (const token of tokens as Walkable[]) {
      if (token.type === 'codespan') {
        const path = codespanFilePath(unescapeMarked(token.text ?? ''));
        if (path) seen.add(path);
        continue;
      }
      if (token.type === 'code') continue;
      if (token.tokens) walk(token.tokens);
      if (token.items) for (const item of token.items) walk(item.tokens ?? []);
      if (token.header) for (const cell of token.header) walk(cell.tokens ?? []);
      if (token.rows) for (const row of token.rows) for (const cell of row) walk(cell.tokens ?? []);
    }
  };
  walk(lexAgentMarkdown(text));
  return [...seen];
}
