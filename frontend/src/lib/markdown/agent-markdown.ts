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
